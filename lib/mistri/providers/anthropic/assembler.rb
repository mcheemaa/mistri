# frozen_string_literal: true

module Mistri
  module Providers
    class Anthropic
      # Folds the Messages API stream into the event union, building the
      # assistant message block by block. Every emitted event carries an
      # immutable snapshot of the message so far; in-flight tool arguments
      # parse via PartialJson so consumers can read them mid-stream.
      #
      # Unknown event and block types are skipped by contract: the API adds
      # types over time and a live stream must survive them.
      class Assembler
        def initialize(model:)
          @model = model
          @blocks = []
          @current = nil
          @usage = Usage.zero
          @stop_reason = nil
          @done = false
        end

        def feed(record, &)
          case record["type"]
          when "message_start" then @usage = parse_usage(record.dig("message", "usage"))
          when "content_block_start" then start_block(record, &)
          when "content_block_delta" then delta_block(record, &)
          when "content_block_stop" then stop_block(record, &)
          when "message_delta" then message_delta(record)
          when "message_stop" then @done = true
          when "error" then @error = record.dig("error", "message") || "provider error"
          end
        end

        # Close the stream: the terminal event reflects how it ended.
        def finish(&emit)
          return fail_stream(@error, &emit) if @error
          return abort(&emit) unless @done

          @message = assemble(stop_reason: @stop_reason || StopReason::STOP)
          emit&.call(Event.new(type: :done, reason: @message.stop_reason, message: @message))
          @message
        end

        def abort(&emit)
          finalize_current
          @message = assemble(stop_reason: StopReason::ABORTED, error_message: "aborted")
          emit&.call(Event.new(type: :error, reason: StopReason::ABORTED, message: @message,
                               error_message: "aborted"))
          @message
        end

        def fail_stream(reason, &emit)
          finalize_current
          text = reason.is_a?(Exception) ? "#{reason.class}: #{reason.message}" : reason.to_s
          @message = assemble(stop_reason: StopReason::ERROR, error_message: text)
          emit&.call(Event.new(type: :error, reason: StopReason::ERROR, message: @message,
                               error_message: text))
          @message
        end

        def message = @message ||= finish

        Builder = Struct.new(:kind, :index, :text, :json, :signature, :id, :name, :redacted)

        private

        def start_block(record, &)
          block = record["content_block"] || {}
          kind = { "text" => :text, "thinking" => :thinking, "redacted_thinking" => :thinking,
                   "tool_use" => :toolcall }[block["type"]]
          return unless kind

          @current = Builder.new(kind, @blocks.size, +"", +"", nil,
                                 block["id"], block["name"], block["type"] == "redacted_thinking")
          @current.signature = block["data"] if @current.redacted
          emit_event(:"#{kind}_start", content_index: @current.index, &)
        end

        def delta_block(record, &)
          return unless @current

          delta = record["delta"] || {}
          case delta["type"]
          when "text_delta" then text_delta(delta["text"], &)
          when "thinking_delta" then thinking_delta(delta["thinking"], &)
          when "signature_delta"
            @current.signature = "#{@current.signature}#{delta["signature"]}"
          when "input_json_delta" then input_delta(delta["partial_json"], &)
          end
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
          @current.json << fragment.to_s
          emit_event(:toolcall_delta, content_index: @current.index, delta: fragment, &)
        end

        def stop_block(_record, &)
          return unless @current

          block = finalize_current
          kind = block.is_a?(ToolCall) ? :toolcall : block.type
          fields = { content_index: @blocks.size - 1 }
          fields[:tool_call] = block if block.is_a?(ToolCall)
          fields[:content] = @blocks.last.is_a?(ToolCall) ? nil : builder_text(block)
          emit_event(:"#{kind}_end", **fields.compact, &)
        end

        def message_delta(record)
          reason = record.dig("delta", "stop_reason")
          @stop_reason = map_stop_reason(reason) if reason
          # message_delta usage is cumulative; merge output counts over the
          # opening snapshot rather than summing.
          output = record.dig("usage", "output_tokens")
          @usage = @usage.with(output: output.to_i) if output
        end

        def finalize_current
          return unless @current

          built = build_block(@current)
          @blocks << built
          @current = nil
          built
        end

        def build_block(builder)
          case builder.kind
          when :text then Content::Text.new(text: builder.text)
          when :thinking
            Content::Thinking.new(thinking: builder.text, signature: builder.signature,
                                  redacted: builder.redacted)
          when :toolcall
            ToolCall.new(id: builder.id, name: builder.name,
                         arguments: parsed_arguments(builder.json), signature: nil)
          end
        end

        def parsed_arguments(json)
          parsed = json.strip.empty? ? {} : PartialJson.parse(json)
          parsed.is_a?(Hash) ? parsed : {}
        end

        def builder_text(block)
          block.respond_to?(:text) ? block.text : block.thinking
        end

        def emit_event(type, **fields, &emit)
          emit&.call(Event.new(type:, partial: assemble, **fields))
        end

        def assemble(**meta)
          blocks = @blocks.dup
          blocks << build_block(@current) if @current
          Message.assistant(content: blocks, model: @model, provider: :anthropic,
                            usage: @usage, **meta)
        end

        def map_stop_reason(reason)
          { "end_turn" => StopReason::STOP, "stop_sequence" => StopReason::STOP,
            "max_tokens" => StopReason::LENGTH,
            "tool_use" => StopReason::TOOL_USE }.fetch(reason, StopReason::STOP)
        end

        def parse_usage(raw)
          return Usage.zero unless raw

          cache_creation = raw["cache_creation"] || {}
          Usage.new(input: raw["input_tokens"].to_i, output: raw["output_tokens"].to_i,
                    cache_read: raw["cache_read_input_tokens"].to_i,
                    cache_write: raw["cache_creation_input_tokens"].to_i,
                    cache_write_1h: cache_creation["ephemeral_1h_input_tokens"].to_i)
        end
      end
    end
  end
end
