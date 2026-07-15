# frozen_string_literal: true

require "json"
require "securerandom"

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
        def initialize(model:, catalog_pricing: true, service_tier: nil)
          @model = model
          @catalog_pricing = catalog_pricing
          @service_tier = service_tier
          @pricing_at = Time.now
          @blocks = []
          @current = nil
          @usage = Usage.new
          @finish_reason = nil
          @terminal = false
        end

        # Finish reasons that are the provider's verdict on the content
        # itself: a retry of the same input meets the same filter, and a
        # harness that re-rolls against a policy verdict is machinery for
        # evading it, so these fail fast.
        VERDICTS = %w[SAFETY RECITATION LANGUAGE BLOCKLIST PROHIBITED_CONTENT SPII
                      IMAGE_SAFETY IMAGE_PROHIBITED_CONTENT IMAGE_RECITATION].freeze
        # Missing replay state accuses the request rather than the generated
        # content, but retrying the same history is equally deterministic.
        INPUT_ERRORS = %w[MISSING_THOUGHT_SIGNATURE].freeze
        # The model fumbled its own output (an invalid or runaway tool call,
        # a missing image), or the API stopped for a reason it cannot name
        # (OTHER is documented as "Unknown reason"). The input stands accused
        # of nothing, so these error retryably; a regeneration usually lands.
        FUMBLES = %w[MALFORMED_FUNCTION_CALL UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS
                     NO_IMAGE OTHER IMAGE_OTHER MALFORMED_RESPONSE
                     FINISH_REASON_UNSPECIFIED].freeze

        def start(&emit)
          emit&.call(Event.new(type: :start, partial: assemble))
        end

        def feed(record, &)
          return after_terminal(record, &) if @terminal
          return record_error(record["error"]) if record["error"]

          fold_record(record, &)
        end

        def after_terminal(record, &)
          return ingest_usage(record) unless terminal_content?(record)

          protocol_error("stream continued after its terminal record", &)
        end

        def record_error(error)
          @error = ProviderError.new(error["message"] || "provider error",
                                     status: error["code"])
          @terminal = true
        end

        def fold_record(record, &)
          block = record.dig("promptFeedback", "blockReason").to_s
          @block_reason = block unless block.empty? || block == "BLOCK_REASON_UNSPECIFIED"
          candidate = record.dig("candidates", 0) || {}
          Array(candidate.dig("content", "parts")).each_with_index do |part, index|
            fold_part(part, part_boundary: index.positive?, &)
          end
          # Grounding accumulates across records; the last snapshot is the
          # complete one and folds into a block when the stream finishes.
          @grounding = candidate["groundingMetadata"] if candidate["groundingMetadata"]
          @finish_reason = candidate["finishReason"] if candidate["finishReason"]
          @terminal = true if @finish_reason || @block_reason
          close_current(&) if @terminal
          ingest_usage(record)
        end
        private :after_terminal, :record_error, :fold_record

        # A stream that ended without a finishReason was truncated, not
        # cancelled: fail it so the loop can treat it as retryable.
        def finish(&emit)
          return fail_stream(@error, &emit) if @error
          if (refused = blocked)
            return fail_stream(refused, usage_known: @usage_authoritative, &emit)
          end
          return fail_stream("stream ended without a finish reason", &emit) unless @finish_reason

          if @blocks.any?(ToolCall) && !%w[STOP MAX_TOKENS].include?(@finish_reason)
            invalidate_tool_calls
            reason = ProviderError.new("generation ended before its tool calls were confirmed: " \
                                       "#{@finish_reason}")
            return fail_stream(reason, usage_known: @usage_authoritative, &emit)
          end

          close_current(&emit)
          fold_grounding(&emit)
          invalidate_cost unless @usage_authoritative
          @message = assemble(stop_reason: stop_reason)
          emit&.call(Event.new(type: :done, reason: @message.stop_reason, message: @message))
          @message
        end

        def abort(&)
          close_current(&)
          invalidate_cost
          terminal(StopReason::ABORTED, "aborted", &)
        end

        def fail_stream(reason, usage_known: false, &)
          close_current(&)
          invalidate_cost unless usage_known
          text = case reason
                 when ProviderError then "#{reason.class}: #{reason.describe}"
                 when Exception then "#{reason.class}: #{reason.message}"
                 else reason.to_s
                 end
          terminal(StopReason::ERROR, text, error: ErrorData.for(reason), &)
        end

        def message = @message ||= finish

        Builder = Struct.new(:kind, :index, :text, :signature)

        private

        def fold_part(part, part_boundary: false, &)
          if part.key?("functionCall")
            fold_function_call(part, &)
          elsif part.key?("text")
            fold_text(part, part["thought"] ? :thinking : :text, part_boundary:, &)
          end
        end

        def terminal_content?(record)
          return true if record["error"]
          return true unless record.dig("promptFeedback", "blockReason").to_s.empty?

          candidate = record.dig("candidates", 0)
          candidate && (candidate["finishReason"] ||
            !Array(candidate.dig("content", "parts")).empty?)
        end

        def ingest_usage(record)
          raw = record["usageMetadata"]
          return unless raw

          @service_tier = raw["serviceTier"] if raw.key?("serviceTier")
          @usage = priced(parse_usage(raw))
          @usage_authoritative = true if @terminal
        end

        def protocol_error(message, &)
          @error ||= ProviderError.new(message)
          close_current(&)
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

        def fold_text(part, kind, part_boundary:, &)
          close_current(&) if @current && (@current.kind != kind || part_boundary ||
                                           @current.signature)
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
          arguments = call_spec.key?("args") ? call_spec["args"] : {}
          wire_id = call_spec["id"]
          call = ToolCall.new(id: wire_id || "gemini_#{SecureRandom.uuid}",
                              name: call_spec["name"], arguments: arguments,
                              signature: part["thoughtSignature"], provider_call_id: wire_id)
          index = @blocks.size
          emit_event(:toolcall_start, content_index: index, &)
          emit_event(:toolcall_delta, content_index: index,
                                      delta: JSON.generate(call.arguments), &)
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

        # Search grounding has no part of its own: it rides the candidate as
        # metadata, so it lands as one block once the content is complete.
        def fold_grounding(&)
          return unless @grounding

          block = Content::ServerToolResult.new(tool_call_id: "google_search",
                                                name: "google_search", payload: @grounding)
          index = @blocks.size
          emit_event(:server_tool_result_start, content_index: index, &)
          @blocks << block
          @grounding = nil
          emit_event(:server_tool_result_end, content_index: index, &)
        end

        # A blocked prompt arrives as promptFeedback with no candidates; a
        # blocked candidate arrives as a verdict finishReason. Either way the
        # error carries the wire word, so hosts tell SAFETY from RECITATION
        # without parsing prose.
        def blocked
          if @block_reason
            return InvalidRequestError.new("the prompt was blocked: #{@block_reason}")
          end
          return unless @finish_reason
          if VERDICTS.include?(@finish_reason) || INPUT_ERRORS.include?(@finish_reason)
            return InvalidRequestError.new("generation stopped: #{@finish_reason}")
          end
          return unless FUMBLES.include?(@finish_reason)

          ProviderError.new("generation stopped: #{@finish_reason}")
        end

        def stop_reason
          return StopReason::LENGTH if @finish_reason == "MAX_TOKENS"
          return StopReason::TOOL_USE if @blocks.any?(ToolCall)

          StopReason::STOP
        end

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

        def priced(usage)
          return usage unless @catalog_pricing

          standard = @service_tier.nil? || %w[unspecified standard].include?(@service_tier.to_s)
          return usage unless standard

          rates = Models.rates(@model, usage:, at: @pricing_at)
          rates ? usage.with_cost(rates) : usage
        end

        def invalidate_cost
          @usage = @usage.with(cost: @usage.cost.with(known: false))
        end
      end
    end
  end
end
