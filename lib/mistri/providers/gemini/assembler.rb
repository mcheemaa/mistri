# frozen_string_literal: true

require "json"

module Mistri
  module Providers
    class Gemini
      # Folds streamGenerateContent records into the event union. Each record
      # carries delta parts: plain text extends a text block, thought parts a
      # thinking block, and a functionCall arrives whole, so its three events
      # emit back to back. A kind switch closes the open block.
      #
      # Thought signatures ride on individual parts and are captured onto the
      # block they arrived with, verbatim, for replay.
      class Assembler
        def initialize(model:)
          @model = model
          @blocks = []
          @current = nil
          @usage = Usage.zero
          @finish_reason = nil
        end

        def feed(record, &)
          if (error = record["error"])
            @error = error["message"] || "provider error"
            return
          end

          candidate = record.dig("candidates", 0) || {}
          Array(candidate.dig("content", "parts")).each { |part| fold_part(part, &) }
          @finish_reason = candidate["finishReason"] if candidate["finishReason"]
          @usage = parse_usage(record["usageMetadata"]) if record["usageMetadata"]
        end

        # A stream that ended without a finishReason was truncated, not
        # cancelled: fail it so the loop can treat it as retryable.
        def finish(&emit)
          return fail_stream(@error, &emit) if @error
          return fail_stream("stream ended without a finish reason", &emit) unless @finish_reason

          close_current(&emit)
          @message = assemble(stop_reason: stop_reason)
          emit&.call(Event.new(type: :done, reason: @message.stop_reason, message: @message))
          @message
        end

        def abort(&)
          close_current
          terminal(StopReason::ABORTED, "aborted", &)
        end

        def fail_stream(reason, &)
          close_current
          text = case reason
                 when ProviderError then "#{reason.class}: #{reason.describe}"
                 when Exception then "#{reason.class}: #{reason.message}"
                 else reason.to_s
                 end
          terminal(StopReason::ERROR, text, &)
        end

        def message = @message ||= finish

        Builder = Struct.new(:kind, :index, :text, :signature)

        private

        def fold_part(part, &)
          if part.key?("functionCall")
            fold_function_call(part, &)
          elsif part.key?("text")
            fold_text(part, part["thought"] ? :thinking : :text, &)
          end
        end

        def fold_text(part, kind, &)
          close_current(&) if @current && @current.kind != kind
          unless @current
            @current = Builder.new(kind, @blocks.size, +"", nil)
            emit_event(:"#{kind}_start", content_index: @current.index, &)
          end
          @current.text << part["text"].to_s
          @current.signature = part["thoughtSignature"] if part["thoughtSignature"]
          delta_type = kind == :text ? :text_delta : :thinking_delta
          emit_event(delta_type, content_index: @current.index, delta: part["text"], &)
        end

        # A function call arrives complete in one part: start, one delta with
        # the full arguments, end.
        def fold_function_call(part, &)
          close_current(&)
          call_spec = part["functionCall"] || {}
          arguments = call_spec["args"].is_a?(Hash) ? call_spec["args"] : {}
          call = ToolCall.new(id: call_spec["id"] || "call_#{@blocks.size + 1}",
                              name: call_spec["name"], arguments: arguments,
                              signature: part["thoughtSignature"])
          index = @blocks.size
          emit_event(:toolcall_start, content_index: index, &)
          emit_event(:toolcall_delta, content_index: index,
                                      delta: JSON.generate(arguments), &)
          @blocks << call
          emit_event(:toolcall_end, content_index: index, tool_call: call, &)
        end

        def close_current(&)
          return unless @current

          block = build_current
          @blocks << block
          kind = @current.kind
          index = @current.index
          @current = nil
          emit_event(:"#{kind}_end", content_index: index,
                                     content: kind == :text ? block.text : block.thinking, &)
        end

        def build_current
          if @current.kind == :text
            Content::Text.new(text: @current.text, signature: @current.signature)
          else
            Content::Thinking.new(thinking: @current.text, signature: @current.signature)
          end
        end

        def stop_reason
          return StopReason::TOOL_USE if @blocks.any?(ToolCall)
          return StopReason::LENGTH if @finish_reason == "MAX_TOKENS"

          StopReason::STOP
        end

        def terminal(reason, text, &emit)
          @message = assemble(stop_reason: reason, error_message: text)
          emit&.call(Event.new(type: :error, reason: reason, message: @message,
                               error_message: text))
          @message
        end

        def emit_event(type, **fields, &emit)
          emit&.call(Event.new(type:, partial: assemble, **fields))
        end

        def assemble(**meta)
          blocks = @blocks.dup
          blocks << build_current if @current
          Message.assistant(content: blocks, model: @model, provider: :gemini,
                            usage: @usage, **meta)
        end

        def parse_usage(raw)
          prompt = raw["promptTokenCount"].to_i
          cache_read = raw["cachedContentTokenCount"].to_i
          reasoning = raw["thoughtsTokenCount"].to_i
          Usage.new(input: [prompt - cache_read, 0].max,
                    output: raw["candidatesTokenCount"].to_i + reasoning,
                    cache_read: cache_read, reasoning: reasoning)
        end
      end
    end
  end
end
