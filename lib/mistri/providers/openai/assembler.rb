# frozen_string_literal: true

require "json"

module Mistri
  module Providers
    class OpenAI
      # Folds the Responses API stream into the event union. Items arrive
      # sequentially: output_item.added opens a block, typed deltas fill it,
      # output_item.done closes it with the complete item, whose ids and
      # encrypted reasoning land in the signature slots for replay.
      #
      # Argument deltas expose a bounded, cached preview; the completed item
      # stays authoritative. Unknown event and item types are skipped by contract.
      class Assembler # rubocop:disable Metrics/ClassLength -- one stream owns item order
        def initialize(model:, catalog_pricing: true)
          @model = model
          @catalog_pricing = catalog_pricing
          @pricing_at = Time.now
          @blocks = []
          @current = nil
          @usage = Usage.new
          @status = nil
          @incomplete_reason = nil
        end

        def feed(record, &)
          type = record["type"]
          if @status && STREAM_EVENTS.include?(type)
            return protocol_error("response continued after its terminal event", &)
          end

          dispatch_record(record, &)
        end

        def dispatch_record(record, &)
          type = record["type"]
          case type
          when "response.output_item.added" then start_item(record, &)
          when "response.output_text.delta" then text_delta(record, &)
          when "response.reasoning_summary_text.delta"
            thinking_delta(record, &)
          when "response.refusal.delta" then refusal_delta(record, &)
          when "response.function_call_arguments.delta" then arguments_delta(record, &)
          when "response.output_item.done" then finish_item(record, &)
          when "response.completed", "response.incomplete", "response.failed"
            finish_response(record, &)
          when "error" then @error ||= wire_error(record)
          end
        end
        private :dispatch_record

        # A stream that ended without a terminal response event was truncated,
        # not cancelled: fail it so the loop can treat it as retryable.
        def finish(&emit)
          return fail_stream(@error, &emit) if @error
          return fail_stream(@refusal_error, &emit) if @refusal_error
          return fail_stream(filter_error, &emit) if @incomplete_reason == "content_filter"

          if @status == "incomplete" && @incomplete_reason != "max_output_tokens"
            detail = @incomplete_reason || "unspecified reason"
            return fail_stream("response was incomplete: #{detail}", &emit)
          end
          return fail_stream("stream ended without a terminal event", &emit) unless @status
          return fail_stream("output item ended without output_item.done", &emit) if @current

          @message = assemble(final: true, stop_reason: stop_reason)
          emit&.call(Event.new(type: :done, reason: @message.stop_reason, message: @message))
          @message
        end

        def abort(&)
          terminal(StopReason::ABORTED, "aborted", &)
        end

        # In-stream failures carry a code; rate limits and server errors must
        # classify as retryable, not fold into prose.
        def wire_error(record)
          message = record["message"] || "provider error"
          code = record["code"].to_s
          classify_error(code, message, unknown: ProviderError)
        end

        def fail_stream(reason, &)
          text = case reason
                 when ProviderError then "#{reason.class}: #{reason.describe}"
                 when Exception then "#{reason.class}: #{reason.message}"
                 else reason.to_s
                 end
          terminal(StopReason::ERROR, text, error: ErrorData.for(reason), &)
        end

        def message = @message ||= finish

        Builder = Struct.new(:kind, :index, :output_index, :text, :json,
                             :argument_bytes, :argument_error,
                             :argument_preview, :preview_bytes, :item_id, :call_id, :name)
        KINDS = { "message" => :text, "reasoning" => :thinking,
                  "function_call" => :toolcall }.freeze
        STREAM_EVENTS = %w[
          response.output_item.added response.output_text.delta
          response.reasoning_summary_text.delta response.refusal.delta
          response.function_call_arguments.delta response.output_item.done
          response.completed response.incomplete response.failed error
        ].freeze
        TERMINAL_STATUSES = {
          "response.completed" => "completed",
          "response.incomplete" => "incomplete",
          "response.failed" => "failed"
        }.freeze
        PREVIEW_EAGER_BYTES = 4 * 1024
        PREVIEW_STEP_BYTES = 4 * 1024
        PREVIEW_MAX_BYTES = 64 * 1024
        MAX_REFUSAL_BYTES = 2048

        def start(&emit)
          emit&.call(Event.new(type: :start, partial: assemble))
        end

        private

        def start_item(record, &)
          return if @error
          if @current
            return protocol_error("response opened an output item before closing the prior item", &)
          end

          item = record["item"]
          kind = KINDS[item&.fetch("type", nil)]
          return unless kind

          @current = Builder.new(kind, @blocks.size, record["output_index"], +"", +"", 0, nil,
                                 ToolArguments::EMPTY_OBJECT, 0,
                                 item["id"], item["call_id"], item["name"])
          @summary_part = nil
          emit_event(:"#{kind}_start", content_index: @current.index, &)
        end

        def text_delta(record, &)
          return unless matching_current?(:text, "output text delta", record, &)

          @current.text << record["delta"].to_s
          emit_event(:text_delta, content_index: @current.index, delta: record["delta"], &)
        end

        # A reasoning item carries one or more summary parts, each its own
        # paragraph; the boundary streams as a delta so live views keep the
        # break the finished text will have.
        def thinking_delta(record, &)
          return unless matching_current?(:thinking, "reasoning summary delta", record, &)

          part = record["summary_index"]
          if @summary_part && part && part != @summary_part
            @current.text << "\n\n"
            emit_event(:thinking_delta, content_index: @current.index, delta: "\n\n", &)
          end
          @summary_part = part if part
          @current.text << record["delta"].to_s
          emit_event(:thinking_delta, content_index: @current.index, delta: record["delta"], &)
        end

        def arguments_delta(record, &)
          return unless matching_current?(:toolcall, "function arguments delta", record, &)

          append_arguments(@current, record["delta"].to_s)
          emit_event(:toolcall_delta, content_index: @current.index, delta: record["delta"], &)
        end

        def refusal_delta(record, &)
          return unless matching_current?(:text, "refusal delta", record, &)

          available = MAX_REFUSAL_BYTES - (@refusal_preview&.bytesize || 0)
          accepted = available.positive? ? bounded_utf8(record["delta"], available) : ""
          @refusal_preview ||= +""
          @refusal_preview << accepted
          unless accepted.empty?
            @current.text << accepted
            emit_event(:text_delta, content_index: @current.index, delta: accepted, &)
          end
          @refusal_error = refusal_from(@refusal_preview)
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

        # The done item is authoritative: its text, arguments, ids, and
        # encrypted content replace whatever the deltas accumulated.
        def finish_item(record, &)
          return if @error

          item = record["item"]
          kind = KINDS[item&.fetch("type", nil)]
          return unless kind || @current

          problem = completed_item_problem(record, item, kind)
          return protocol_error(problem, &) if problem
          return if finish_refusal?(item, kind, &)

          commit_item(item, kind, &)
        end

        def completed_item_problem(record, item, kind)
          return "response closed an output item that was never opened" unless @current
          unless kind == @current.kind
            return "response changed an output item's type before closing it"
          end
          if @current.item_id && item["id"] && item["id"] != @current.item_id
            return "response closed a different output item than it opened"
          end
          if @current.output_index && record["output_index"] &&
             record["output_index"] != @current.output_index
            return "response closed an unexpected output index"
          end

          nil
        end

        def finish_refusal?(item, kind, &)
          return false unless kind == :text && (error = refusal_error(item))

          index = @current.index
          @refusal_error = error
          if @current.text.empty?
            @current = nil
            emit_event(:text_end, content_index: index, content: "", &)
          else
            close_current(&)
          end
          true
        end

        def commit_item(item, kind, &)
          index = @current.index
          block = build_block(kind, item, streamed: @current)
          @blocks << block
          @current = nil
          fields = { content_index: index }
          fields[:tool_call] = block if block.is_a?(ToolCall)
          unless block.is_a?(ToolCall)
            fields[:content] = block.respond_to?(:text) ? block.text : block.thinking
          end
          emit_event(:"#{kind}_end", **fields.compact, &)
        end

        # A refusal is an explicit provider verdict outside the requested
        # schema, not an empty successful answer to send through a fix loop.
        def refusal_error(item)
          part = Array(item["content"]).find { |candidate| candidate["type"] == "refusal" }
          return unless part

          detail = bounded_refusal(part["refusal"])
          refusal_from(detail)
        end

        def refusal_from(detail)
          message = "OpenAI refused the request"
          message = "#{message}: #{detail}" unless detail.empty?
          InvalidRequestError.new(message)
        end

        def bounded_refusal(value)
          bounded_utf8(value, MAX_REFUSAL_BYTES)
        end

        def bounded_utf8(value, limit)
          return "" unless value.is_a?(String)

          prefix = value.byteslice(0, limit).dup.force_encoding(value.encoding)
          prefix.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
                .scrub.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8).scrub
        end

        def build_block(kind, item, streamed: nil)
          case kind
          when :text
            text = Array(item["content"]).filter_map { |part| part["text"] }.join
            Content::Text.new(text: text, signature: item["id"])
          when :thinking
            summary = Array(item["summary"]).filter_map { |part| part["text"] }.join("\n\n")
            Content::Thinking.new(thinking: summary, signature: JSON.generate(item))
          when :toolcall
            arguments, error = if item.key?("arguments")
                                 ToolArguments.parse_json(item["arguments"])
                               elsif streamed&.argument_error
                                 [nil, streamed.argument_error]
                               else
                                 [nil, "invalid_json"]
                               end
            ToolCall.new(id: item["call_id"], name: item["name"],
                         arguments:, signature: item["id"], arguments_error: error)
          end
        end

        def finish_response(record, &)
          response = record["response"] || {}
          if @current
            protocol_error("response ended before output_item.done closed its output item",
                           &)
          end
          expected = TERMINAL_STATUSES.fetch(record["type"])
          if response["status"] && response["status"] != expected
            protocol_error("response terminal event disagreed with its status", &)
          end
          @status = expected
          @incomplete_reason = response.dig("incomplete_details", "reason")
          @error ||= failure_error(response["error"]) if @status == "failed"
          @service_tier = response["service_tier"]
          usage = response["usage"]
          @usage = priced(parse_usage(usage)) if usage
        end

        # A failed response is the provider's verdict on this input, not a
        # transport accident: only its documented transient codes retry
        # (rate limits, server errors, timeouts). Everything else, like
        # invalid_prompt and the image family, cannot succeed on a retry.
        def failure_error(error)
          return ProviderError.new("the response failed without an error") unless error

          code = error["code"].to_s
          message = [code, error["message"] || "the response failed"]
                    .reject(&:empty?).join(": ")
          classify_error(code, message, unknown: InvalidRequestError)
        end

        def classify_error(code, message, unknown:)
          klass = if code.include?("rate_limit") then RateLimitError
                  elsif code.include?("server") then ServerError
                  elsif code.include?("timeout") then ProviderError
                  elsif code.empty? then unknown
                  else InvalidRequestError
                  end
          klass.new(message)
        end

        def stop_reason
          return StopReason::LENGTH if @incomplete_reason == "max_output_tokens"
          return StopReason::TOOL_USE if @blocks.any?(ToolCall)

          StopReason::STOP
        end

        # The spec's only other incomplete reason: a filter cut is a verdict
        # on the content, not a truncation, so it never reads as a clean stop
        # and never retries.
        def filter_error = InvalidRequestError.new("the response was cut by the content filter")

        def terminal(reason, text, error: nil, &emit)
          close_current(interrupted: true, &emit)
          @message = assemble(final: true, stop_reason: reason, error_message: text, error: error)
          emit&.call(Event.new(type: :error, reason: reason, message: @message,
                               error_message: text))
          @message
        end

        def emit_event(type, **fields, &emit)
          emit&.call(Event.new(type:, partial: assemble, **fields))
        end

        def matching_current?(kind, label, record, &)
          return false if @error

          unless @current&.kind == kind
            protocol_error("response sent a #{label} outside its matching output item", &)
            return false
          end
          if @current.item_id && record["item_id"] && record["item_id"] != @current.item_id
            protocol_error("response sent a #{label} for a different output item", &)
            return false
          end
          if @current.output_index && record["output_index"] &&
             record["output_index"] != @current.output_index
            protocol_error("response sent a #{label} for an unexpected output index", &)
            return false
          end

          true
        end

        def protocol_error(message, &)
          @error ||= ProviderError.new(message)
          close_current(interrupted: true, &)
          invalidate_tool_calls
          nil
        end

        def invalidate_tool_calls
          @blocks.map! do |block|
            if block.is_a?(ToolCall)
              block.with(arguments: nil, arguments_error: "incomplete")
            else
              block
            end
          end
        end

        def close_current(interrupted: false, &)
          return unless @current

          builder = @current
          block = interrupted ? interrupted_block(builder) : partial_block(builder, final: true)
          @blocks << block
          @current = nil
          fields = { content_index: builder.index }
          fields[:tool_call] = block if block.is_a?(ToolCall)
          unless block.is_a?(ToolCall)
            fields[:content] = block.respond_to?(:text) ? block.text : block.thinking
          end
          emit_event(:"#{builder.kind}_end", **fields, &)
          block
        end

        def interrupted_block(builder)
          case builder.kind
          when :text then Content::Text.new(text: builder.text)
          when :thinking then Content::Thinking.new(thinking: builder.text)
          when :toolcall
            ToolCall.new(id: builder.call_id, name: builder.name, arguments: nil,
                         signature: builder.item_id, arguments_error: "incomplete")
          end
        end

        def assemble(final: false, **meta)
          blocks = @blocks.dup
          if @current && (block = partial_block(@current, final:))
            blocks << block
          end
          Message.assistant(content: blocks, model: @model, provider: :openai,
                            usage: @usage, **meta)
        end

        def partial_block(builder, final: false)
          case builder.kind
          when :text then Content::Text.new(text: builder.text)
          when :thinking then Content::Thinking.new(thinking: builder.text)
          when :toolcall
            return nil if final

            ToolCall.new(id: "pending", name: "pending",
                         arguments: builder.argument_preview, canonicalize: false)
          end
        end

        def parse_usage(raw)
          details = raw["input_tokens_details"] || {}
          output_details = raw["output_tokens_details"] || {}
          cache_read = details["cached_tokens"].to_i
          cache_write = details["cache_write_tokens"].to_i
          input = [raw["input_tokens"].to_i - cache_read - cache_write, 0].max
          Usage.new(input:, output: raw["output_tokens"].to_i, cache_read:,
                    cache_write:,
                    reasoning: output_details["reasoning_tokens"].to_i)
        end

        def priced(usage)
          return usage unless @catalog_pricing
          return usage unless @service_tier == "default"

          rates = Models.rates(@model, usage:, at: @pricing_at)
          rates ? usage.with_cost(rates) : usage
        end
      end # rubocop:enable Metrics/ClassLength
    end
  end
end
