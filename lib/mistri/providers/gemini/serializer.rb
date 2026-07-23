# frozen_string_literal: true

module Mistri
  module Providers
    class Gemini
      # Serializes protocol messages into generateContent contents.
      #
      # Wire rules that matter: roles are user and model, consecutive tool
      # results merge into one user turn of functionResponse parts, and
      # thought signatures echo back verbatim on the exact part they arrived
      # with, but only for messages this provider produced; a foreign
      # signature would be rejected. Thinking summaries are output-only and
      # never replay. Consecutive user turns stay separate: Gemini accepts
      # them, and mixing a text part into a functionResponse turn makes it
      # answer an empty candidate. Completed tool exchanges from another
      # provider become ordinary text: Gemini rejects foreign functionCall
      # history because it has no Gemini thought signature.
      module Serializer
        module_function

        def contents(history)
          result_metadata = tool_result_metadata(history)
          groups = history.reject(&:system?).chunk_while do |a, b|
            a.tool? && b.tool? && native_tool_result?(a, result_metadata) ==
              native_tool_result?(b, result_metadata)
          end
          groups.filter_map do |group|
            if group.first.tool?
              if native_tool_result?(group.first, result_metadata)
                tool_turn(group, result_metadata)
              else
                foreign_tool_turn(group)
              end
            else
              turn(group.first)
            end
          end
        end

        def system_instruction(system)
          return nil if system.nil? || system.empty?

          { parts: [{ text: system }] }
        end

        def tools(definitions)
          hosted, functions = definitions.partition { |tool| tool.is_a?(WebSearch) }
          declarations = functions.map do |tool|
            spec = tool.transform_keys(&:to_sym)
            { name: spec[:name], description: spec[:description],
              parametersJsonSchema: spec[:input_schema] }
          end
          wire = []
          wire << { functionDeclarations: declarations } if declarations.any?
          wire << { googleSearch: {} } if hosted.any?
          wire
        end

        def turn(msg)
          parts = msg.assistant? ? assistant_parts(msg) : user_parts(msg)
          return nil if parts.empty?

          { role: msg.assistant? ? "model" : "user", parts: parts }
        end

        # Gemini pairs a functionResponse to its call by NAME; a wrong name
        # silently mismatches, so a missing one fails loudly instead.
        def tool_turn(group, result_metadata = {}.compare_by_identity)
          { role: "user", parts: group.map do |msg|
            unless msg.tool_name
              raise SchemaError, "Gemini tool results need tool_name to pair with their call"
            end

            key = msg.tool_error? ? "error" : "result"
            response = { name: msg.tool_name, response: { key => result_text(msg) } }
            wire_id = result_metadata.dig(msg, :provider_call_id)
            response[:id] = wire_id if wire_id
            { functionResponse: response }
          end }
        end

        def foreign_tool_turn(group)
          { role: "user", parts: group.map do |msg|
            raise SchemaError, "Gemini tool results need tool_name" unless msg.tool_name

            label = msg.tool_error? ? "error" : "result"
            text = "Tool #{JSON.generate(msg.tool_name)} #{label} " \
                   "(call #{JSON.generate(msg.tool_call_id)}): #{result_text(msg)}"
            { text: text }
          end }
        end

        # Non-text blocks in a tool result have no functionResponse encoding;
        # note the omission rather than dropping it silently.
        def result_text(msg)
          omitted = msg.content.count { |block| !block.is_a?(Content::Text) }
          text = msg.text.to_s
          omitted.positive? ? "#{text}\n[#{omitted} non-text block(s) omitted]".strip : text
        end

        def user_parts(msg)
          msg.content.map do |block|
            case block
            when Content::Text then { text: block.text }
            when Content::Image
              { inlineData: { mimeType: block.mime_type, data: block.data } }
            else
              raise SchemaError, "cannot serialize #{block.class} for Gemini user input"
            end
          end
        end

        # Server-tool blocks never replay: grounding is response metadata the
        # API does not accept back, and Gemini rejects parts it did not sign.
        def assistant_parts(msg)
          own = msg.provider == :gemini
          msg.content.filter_map do |block|
            case block
            when Content::Text then signed({ text: block.text }, block.signature, own)
            when ToolCall
              own ? native_function_call(block) : foreign_function_call(block)
            end
          end
        end

        def native_function_call(block)
          arguments = ToolArguments.replay_object(block)
          signature = block.signature if arguments.equal?(block.arguments)
          call = { name: block.name, args: arguments }
          call[:id] = block.provider_call_id if block.provider_call_id
          signed({ functionCall: call }, signature, true)
        end

        def foreign_function_call(block)
          arguments = if block.arguments_error
                        "unavailable (#{block.arguments_error})"
                      else
                        JSON.generate(block.arguments)
                      end
          { text: "Tool call #{JSON.generate(block.name)} " \
                  "(call #{JSON.generate(block.id)}) with arguments: #{arguments}" }
        end

        def native_tool_result?(message, result_metadata)
          result_metadata.dig(message, :provider) == :gemini
        end

        # Legacy histories may reuse call_N across turns. Correlating each
        # result to the nearest preceding occurrence keeps a later Gemini call
        # from rewriting an earlier foreign result's wire semantics.
        def tool_result_metadata(history)
          pending = Hash.new { |calls, id| calls[id] = [] }
          metadata = {}.compare_by_identity
          history.each do |message|
            if message.assistant?
              message.tool_calls.each do |call|
                pending[call.id] << { provider: message.provider,
                                      provider_call_id: call.provider_call_id }.freeze
              end
            elsif message.tool?
              matched = pending[message.tool_call_id].pop
              metadata[message] = matched if matched
            end
          end
          metadata
        end

        def signed(part, signature, own)
          part[:thoughtSignature] = signature if own && signature
          part
        end
      end
    end
  end
end
