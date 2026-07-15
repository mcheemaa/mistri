# frozen_string_literal: true

module Mistri
  module Providers
    class Anthropic
      # Folds the Messages API stream into the event union, building the
      # assistant message block by block. Every emitted event carries an
      # immutable snapshot of the message so far; in-flight tool arguments
      # expose a bounded, cached PartialJson preview so hostile fragmentation
      # cannot make snapshot construction quadratic.
      #
      # Unknown event and block types are skipped by contract: the API adds
      # types over time and a live stream must survive them.
      class Assembler # rubocop:disable Metrics/ClassLength -- one stream owns block order
        def initialize(model:, catalog_pricing: true)
          @model = model
          @catalog_pricing = catalog_pricing
          @pricing_at = Time.now
          @blocks = []
          @current = nil
          @usage = Usage.new
          @stop_reason = nil
          @done = false
          @next_wire_index = 0
          @open_wire_index = nil
          @message_phase = false
        end

        STREAM_EVENTS = %w[
          message_start content_block_start content_block_delta content_block_stop
          message_delta message_stop error
        ].freeze

        def feed(record, &)
          type = record["type"]
          if @done && STREAM_EVENTS.include?(type)
            return protocol_error("stream continued after message_stop", &)
          end

          case type
          when "message_start" then message_start(record)
          when "content_block_start" then start_block(record, &)
          when "content_block_delta" then delta_block(record, &)
          when "content_block_stop" then stop_block(record, &)
          when "message_delta" then message_delta(record, &)
          when "message_stop" then stop_message(&)
          when "error" then @error ||= wire_error(record["error"])
          end
        end

        # Close the stream: the terminal event reflects how it ended. A stream
        # that ended without message_stop was truncated (a dropped proxy, say),
        # not user-aborted, so it fails for the loop to retry rather than
        # reading as a cancellation.
        def finish(&emit)
          return fail_stream(@error, &emit) if @error
          if @refused
            return fail_stream(refusal_error,
                               usage_known: @done && @usage_authoritative, &emit)
          end
          return fail_stream("stream ended without message_stop", &emit) unless @done
          if @open_wire_index
            return fail_stream("content block ended without content_block_stop", &emit)
          end

          invalidate_cost unless @usage_authoritative
          @message = assemble(stop_reason: @stop_reason || StopReason::STOP)
          emit&.call(Event.new(type: :done, reason: @message.stop_reason, message: @message))
          @message
        end

        def abort(&emit)
          close_current(interrupted: true, &emit)
          invalidate_cost
          @message = assemble(stop_reason: StopReason::ABORTED, error_message: "aborted")
          emit&.call(Event.new(type: :error, reason: StopReason::ABORTED, message: @message,
                               error_message: "aborted"))
          @message
        end

        # In-stream failures carry a wire type; overloaded ones must classify
        # as retryable, not fold into prose.
        def wire_error(payload)
          message = payload&.dig("message") || "provider error"
          type = payload&.dig("type").to_s
          klass = case type
                  when "authentication_error" then AuthenticationError
                  when "rate_limit_error" then RateLimitError
                  when "overloaded_error" then OverloadedError
                  when "api_error" then ServerError
                  when "timeout_error" then ProviderError
                  else InvalidRequestError
                  end
          detail = type.empty? ? message : "#{type}: #{message}"
          klass.new(detail)
        end

        def fail_stream(reason, usage_known: false, &emit)
          close_current(interrupted: true, &emit)
          invalidate_cost unless usage_known
          text = case reason
                 when ProviderError then "#{reason.class}: #{reason.describe}"
                 when Exception then "#{reason.class}: #{reason.message}"
                 else reason.to_s
                 end
          @message = assemble(stop_reason: StopReason::ERROR, error_message: text,
                              error: ErrorData.for(reason))
          emit&.call(Event.new(type: :error, reason: StopReason::ERROR, message: @message,
                               error_message: text))
          @message
        end

        def message = @message ||= finish

        Builder = Struct.new(:kind, :index, :text, :json, :signature, :id, :name, :redacted,
                             :argument_bytes, :argument_error, :argument_preview, :preview_bytes,
                             :payload)
        DELTA_KINDS = {
          "text_delta" => %i[text].freeze,
          "thinking_delta" => %i[thinking].freeze,
          "signature_delta" => %i[thinking].freeze,
          "input_json_delta" => %i[toolcall server_tool_call].freeze
        }.freeze

        PREVIEW_EAGER_BYTES = 4 * 1024
        PREVIEW_STEP_BYTES = 4 * 1024
        PREVIEW_MAX_BYTES = 64 * 1024
        MAX_SIGNATURE_BYTES = ToolArguments::MAX_BYTES
        MAX_REFUSAL_BYTES = 2048

        def start(&emit)
          emit&.call(Event.new(type: :start, partial: assemble))
        end

        private

        def message_start(record)
          raw = record.dig("message", "usage")
          @service_tier = raw&.fetch("service_tier", nil)
          @usage = priced(parse_usage(raw))
        end

        def start_block(record, &)
          return if @error
          return protocol_error("stream opened content after the message delta phase", &) \
            if @message_phase
          if @open_wire_index
            return protocol_error("stream opened a content block before closing the prior block", &)
          end

          index = record["index"]
          unless index == @next_wire_index
            return protocol_error("stream opened a content block at an unexpected index", &)
          end

          @open_wire_index = index
          @next_wire_index += 1

          block = record["content_block"] || {}
          if block["type"] == "tool_use" && block.key?("input") &&
             (!block["input"].is_a?(Hash) || !block["input"].empty?)
            return protocol_error("tool_use started with nonempty input before its deltas", &)
          end

          kind = { "text" => :text, "thinking" => :thinking, "redacted_thinking" => :thinking,
                   "tool_use" => :toolcall, "server_tool_use" => :server_tool_call,
                   "web_search_tool_result" => :server_tool_result }[block["type"]]
          return unless kind

          @current = Builder.new(kind, @blocks.size, +"", +"", nil,
                                 block["id"], block["name"], block["type"] == "redacted_thinking",
                                 0, nil, ToolArguments::EMPTY_OBJECT, 0)
          seed_current(block, kind)
          emit_event(:"#{kind}_start", content_index: @current.index, &)
        end

        # A web_search_tool_result block arrives whole with its start event:
        # there are no deltas, and it pairs by the server tool call's id.
        def seed_current(block, kind)
          @current.signature = block["data"] if @current.redacted
          return unless kind == :server_tool_result

          @current.id = block["tool_use_id"]
          @current.name = "web_search"
          @current.payload = block["content"]
        end

        def delta_block(record, &)
          return if @error
          return protocol_error("stream sent content after the message delta phase", &) \
            if @message_phase
          unless @open_wire_index && record["index"] == @open_wire_index
            return protocol_error("stream sent a delta for a different content block", &)
          end
          return unless @current

          delta = record["delta"] || {}
          expected = DELTA_KINDS[delta["type"]]
          return unless expected
          unless expected.include?(@current.kind)
            return protocol_error("stream sent a delta outside its matching content block", &)
          end

          route_delta(delta, &)
        end

        def route_delta(delta, &)
          case delta["type"]
          when "text_delta"
            text_delta(delta["text"], &)
          when "thinking_delta"
            thinking_delta(delta["thinking"], &)
          when "signature_delta"
            signature_delta(delta["signature"])
          when "input_json_delta"
            input_delta(delta["partial_json"], &)
          end
        end

        def signature_delta(fragment)
          fragment = fragment.to_s
          current = @current.signature || +""
          if fragment.bytesize > MAX_SIGNATURE_BYTES - current.bytesize
            raise ResponseTooLargeError.new(kind: :thinking_signature,
                                            limit: MAX_SIGNATURE_BYTES)
          end

          @current.signature = current
          current << fragment
        end

        def text_delta(text, &)
          @current.text << text.to_s
          emit_event(:text_delta, content_index: @current.index, delta: text, &)
        end

        def thinking_delta(text, &)
          @current.text << text.to_s
          emit_event(:thinking_delta, content_index: @current.index, delta: text, &)
        end

        def input_delta(fragment, &)
          append_arguments(@current, fragment.to_s)
          return unless @current.kind == :toolcall

          emit_event(:toolcall_delta, content_index: @current.index, delta: fragment, &)
        end

        def append_arguments(builder, fragment)
          return if builder.argument_error

          if fragment.bytesize > ToolArguments::MAX_BYTES - builder.argument_bytes
            builder.argument_error = "too_large"
            # String#clear may retain its backing allocation.
            builder.json = +""
            return
          end

          builder.json << fragment
          builder.argument_bytes += fragment.bytesize
          refresh_argument_preview(builder)
        end

        def refresh_argument_preview(builder)
          target = [builder.argument_bytes, PREVIEW_MAX_BYTES].min
          eager = target <= PREVIEW_EAGER_BYTES
          milestone = target - builder.preview_bytes >= PREVIEW_STEP_BYTES
          return unless eager || milestone || target == PREVIEW_MAX_BYTES
          return if target == builder.preview_bytes

          source = if target == builder.json.bytesize
                     builder.json
                   else
                     builder.json.byteslice(0, target)
                   end
          builder.argument_preview = ToolArguments.freeze_partial(PartialJson.parse(source))
          builder.preview_bytes = target
        end

        def stop_block(record, &)
          return if @error
          return protocol_error("stream stopped content after the message delta phase", &) \
            if @message_phase
          unless @open_wire_index && record["index"] == @open_wire_index
            return protocol_error("stream stopped a different content block", &)
          end

          close_current(&) if @current
          @open_wire_index = nil
        end

        def message_delta(record, &)
          @message_phase = true
          if @open_wire_index
            return protocol_error("message delta arrived before the content block stopped", &)
          end

          reason = record.dig("delta", "stop_reason")
          @stop_reason = map_stop_reason(reason) if reason
          if reason == "refusal"
            @refused = true
            @refusal = record.dig("delta", "stop_details")
          end
          # message_delta usage is cumulative; merge output counts over the
          # opening snapshot rather than summing.
          output = record.dig("usage", "output_tokens")
          return unless output

          @usage = priced(@usage.with(output: output.to_i))
          @usage_authoritative = true
        end

        def stop_message(&)
          protocol_error("message stopped before the content block stopped", &) if @open_wire_index
          @done = true
        end

        def close_current(interrupted: false, &)
          return unless @current

          built = build_block(@current, interrupted:)
          @blocks << built
          @current = nil
          kind = built.is_a?(ToolCall) ? :toolcall : built.type
          fields = { content_index: @blocks.size - 1 }
          fields[:tool_call] = built if built.is_a?(ToolCall)
          fields[:content] = builder_text(built)
          emit_event(:"#{kind}_end", **fields.compact, &)
          built
        end

        def build_block(builder, final: true, interrupted: false)
          case builder.kind
          when :text then Content::Text.new(text: builder.text)
          when :thinking
            signature = interrupted ? nil : builder.signature
            redacted = interrupted ? false : builder.redacted
            Content::Thinking.new(thinking: builder.text, signature:, redacted:)
          when :toolcall
            arguments, error = if interrupted
                                 [nil, "incomplete"]
                               elsif final
                                 if builder.argument_error
                                   [nil, builder.argument_error]
                                 else
                                   parsed_arguments(builder.json)
                                 end
                               else
                                 [builder.argument_preview, nil]
                               end
            ToolCall.new(id: builder.id, name: builder.name,
                         arguments:, signature: nil, arguments_error: error,
                         canonicalize: final)
          when :server_tool_call, :server_tool_result
            server_block(builder, complete: final && !interrupted)
          end
        end

        # The provider already executed a server tool; malformed or truncated
        # input degrades to an empty object rather than failing the turn.
        def server_block(builder, complete:)
          if builder.kind == :server_tool_result
            return Content::ServerToolResult.new(tool_call_id: builder.id, name: builder.name,
                                                 payload: builder.payload)
          end

          arguments, = complete && !builder.argument_error ? parsed_arguments(builder.json) : [{}]
          arguments = {} unless arguments.is_a?(Hash)
          Content::ServerToolCall.new(id: builder.id, name: builder.name, arguments:)
        end

        def parsed_arguments(json)
          return [{}, nil] if json.empty?

          ToolArguments.parse_json(json)
        end

        def builder_text(block)
          return block.text if block.respond_to?(:text)

          block.respond_to?(:thinking) ? block.thinking : nil
        end

        def emit_event(type, **fields, &emit)
          emit&.call(Event.new(type:, partial: assemble, **fields))
        end

        def protocol_error(message, &)
          @error ||= ProviderError.new(message)
          close_current(interrupted: true, &)
          @blocks.map! do |block|
            if block.is_a?(ToolCall)
              block.with(arguments: nil,
                         arguments_error: "incomplete")
            else
              block
            end
          end
          @open_wire_index = nil
          nil
        end

        def assemble(**meta)
          blocks = @blocks.dup
          blocks << build_block(@current, final: false) if @current
          Message.assistant(content: blocks, model: @model, provider: :anthropic,
                            usage: @usage, **meta)
        end

        # pause_turn (a server tool paused a long turn) maps to tool_use so
        # the loop continues the turn rather than ending it; a filled context
        # window is a truncation, per the API's own guidance.
        def map_stop_reason(reason)
          { "end_turn" => StopReason::STOP, "stop_sequence" => StopReason::STOP,
            "max_tokens" => StopReason::LENGTH, "tool_use" => StopReason::TOOL_USE,
            "model_context_window_exceeded" => StopReason::LENGTH,
            "pause_turn" => StopReason::TOOL_USE }.fetch(reason, StopReason::STOP)
        end

        # The API's guidance for a refusal is a different model, never a
        # retry of this one, so it fails fast; stop_details names the policy
        # category when the API provides one.
        def refusal_error
          details = bounded_refusal(@refusal&.dig("category"),
                                    @refusal&.dig("explanation"))
          text = +"the model refused to respond"
          text << " (#{details})" unless details.empty?
          InvalidRequestError.new(text)
        end

        def bounded_refusal(*values)
          output = +""
          values.each do |value|
            next unless value.is_a?(String)

            separator = output.empty? ? "" : ": "
            remaining = MAX_REFUSAL_BYTES - output.bytesize - separator.bytesize
            break unless remaining.positive?

            output << separator << utf8_prefix(value, remaining)
          end
          output
        end

        def utf8_prefix(value, limit)
          prefix = value.byteslice(0, limit).dup.force_encoding(value.encoding)
          prefix.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
                .scrub.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8).scrub
        end

        def parse_usage(raw)
          return Usage.new unless raw

          cache_creation = raw["cache_creation"] || {}
          Usage.new(input: raw["input_tokens"].to_i, output: raw["output_tokens"].to_i,
                    cache_read: raw["cache_read_input_tokens"].to_i,
                    cache_write: raw["cache_creation_input_tokens"].to_i,
                    cache_write_1h: cache_creation["ephemeral_1h_input_tokens"].to_i)
        end

        def priced(usage)
          return usage unless @catalog_pricing
          return usage unless @service_tier == "standard"

          rates = Models.rates(@model, usage:, at: @pricing_at)
          rates ? usage.with_cost(rates) : usage
        end

        def invalidate_cost
          @usage = @usage.with(cost: @usage.cost.with(known: false))
        end
      end # rubocop:enable Metrics/ClassLength
    end
  end
end
