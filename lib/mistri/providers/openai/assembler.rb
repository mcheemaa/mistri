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
      # Unknown event and item types are skipped by contract.
      class Assembler
        def initialize(model:)
          @model = model
          @rates = Models.rates(model)
          @blocks = []
          @current = nil
          @usage = Usage.zero
          @status = nil
          @incomplete_reason = nil
        end

        def feed(record, &)
          case record["type"]
          when "response.output_item.added" then start_item(record["item"], &)
          when "response.output_text.delta" then text_delta(record["delta"], &)
          when "response.reasoning_summary_text.delta"
            thinking_delta(record["delta"], record["summary_index"], &)
          when "response.function_call_arguments.delta" then arguments_delta(record["delta"], &)
          when "response.output_item.done" then finish_item(record["item"], &)
          when "response.completed", "response.incomplete", "response.failed"
            finish_response(record["response"] || {})
          when "error" then @error = wire_error(record)
          end
        end

        # A stream that ended without a terminal response event was truncated,
        # not cancelled: fail it so the loop can treat it as retryable.
        def finish(&emit)
          return fail_stream(@error, &emit) if @error
          return fail_stream(filter_error, &emit) if @incomplete_reason == "content_filter"
          return fail_stream("stream ended without a terminal event", &emit) unless @status

          @message = assemble(stop_reason: stop_reason)
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
          klass = if code.include?("rate_limit") then RateLimitError
                  elsif code.include?("server") then ServerError
                  else ProviderError
                  end
          klass.new(message)
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

        Builder = Struct.new(:kind, :index, :text, :json)
        KINDS = { "message" => :text, "reasoning" => :thinking,
                  "function_call" => :toolcall }.freeze

        private

        def start_item(item, &)
          kind = KINDS[item&.fetch("type", nil)]
          return unless kind

          @current = Builder.new(kind, @blocks.size, +"", +"")
          @summary_part = nil
          emit_event(:"#{kind}_start", content_index: @current.index, &)
        end

        def text_delta(delta, &)
          return unless @current

          @current.text << delta.to_s
          emit_event(:text_delta, content_index: @current.index, delta: delta, &)
        end

        # A reasoning item carries one or more summary parts, each its own
        # paragraph; the boundary streams as a delta so live views keep the
        # break the finished text will have.
        def thinking_delta(delta, part, &)
          return unless @current

          if @summary_part && part && part != @summary_part
            @current.text << "\n\n"
            emit_event(:thinking_delta, content_index: @current.index, delta: "\n\n", &)
          end
          @summary_part = part if part
          @current.text << delta.to_s
          emit_event(:thinking_delta, content_index: @current.index, delta: delta, &)
        end

        def arguments_delta(delta, &)
          return unless @current

          @current.json << delta.to_s
          emit_event(:toolcall_delta, content_index: @current.index, delta: delta, &)
        end

        # The done item is authoritative: its text, arguments, ids, and
        # encrypted content replace whatever the deltas accumulated.
        def finish_item(item, &)
          kind = KINDS[item&.fetch("type", nil)]
          return unless kind

          index = @current&.index || @blocks.size
          block = build_block(kind, item)
          @blocks << block
          @current = nil
          fields = { content_index: index }
          fields[:tool_call] = block if block.is_a?(ToolCall)
          unless block.is_a?(ToolCall)
            fields[:content] = block.respond_to?(:text) ? block.text : block.thinking
          end
          emit_event(:"#{kind}_end", **fields.compact, &)
        end

        def build_block(kind, item)
          case kind
          when :text
            text = Array(item["content"]).filter_map { |part| part["text"] }.join
            Content::Text.new(text: text, signature: item["id"])
          when :thinking
            summary = Array(item["summary"]).filter_map { |part| part["text"] }.join("\n\n")
            Content::Thinking.new(thinking: summary, signature: JSON.generate(item))
          when :toolcall
            ToolCall.new(id: item["call_id"], name: item["name"],
                         arguments: parse_arguments(item["arguments"]), signature: item["id"])
          end
        end

        def parse_arguments(raw)
          parsed = raw.to_s.strip.empty? ? {} : JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          fallback = PartialJson.parse(raw)
          fallback.is_a?(Hash) ? fallback : {}
        end

        def finish_response(response)
          @status = response["status"] || "completed"
          @incomplete_reason = response.dig("incomplete_details", "reason")
          @error = failure_error(response["error"]) if @status == "failed"
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
          klass = if code.include?("rate_limit") then RateLimitError
                  elsif code.include?("server") then ServerError
                  elsif code.include?("timeout") then ProviderError
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
          @message = assemble(stop_reason: reason, error_message: text, error: error)
          emit&.call(Event.new(type: :error, reason: reason, message: @message,
                               error_message: text))
          @message
        end

        def emit_event(type, **fields, &emit)
          emit&.call(Event.new(type:, partial: assemble, **fields))
        end

        def assemble(**meta)
          blocks = @blocks.dup
          blocks << partial_block(@current) if @current
          Message.assistant(content: blocks, model: @model, provider: :openai,
                            usage: @usage, **meta)
        end

        def partial_block(builder)
          case builder.kind
          when :text then Content::Text.new(text: builder.text)
          when :thinking then Content::Thinking.new(thinking: builder.text)
          when :toolcall
            args = PartialJson.parse(builder.json)
            ToolCall.new(id: "pending", name: "pending",
                         arguments: args.is_a?(Hash) ? args : {})
          end
        end

        def parse_usage(raw)
          details = raw["input_tokens_details"] || {}
          output_details = raw["output_tokens_details"] || {}
          cache_read = details["cached_tokens"].to_i
          Usage.new(input: [raw["input_tokens"].to_i - cache_read, 0].max,
                    output: raw["output_tokens"].to_i, cache_read: cache_read,
                    reasoning: output_details["reasoning_tokens"].to_i)
        end

        def priced(usage) = @rates ? usage.with_cost(@rates) : usage
      end
    end
  end
end
