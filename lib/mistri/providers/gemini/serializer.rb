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
          origins = tool_call_origins(history)
          wire_ids = provider_call_ids(history)
          groups = history.reject(&:system?).chunk_while do |a, b|
            a.tool? && b.tool? && native_tool_result?(a, origins) ==
              native_tool_result?(b, origins)
          end
          groups.filter_map do |group|
            if group.first.tool?
              if native_tool_result?(group.first, origins)
                tool_turn(group, wire_ids)
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
          declarations = definitions.map do |tool|
            spec = tool.transform_keys(&:to_sym)
            { name: spec[:name], description: spec[:description],
              parametersJsonSchema: spec[:input_schema] }
          end
          [{ functionDeclarations: declarations }]
        end

        def turn(msg)
          parts = msg.assistant? ? assistant_parts(msg) : user_parts(msg)
          return nil if parts.empty?

          { role: msg.assistant? ? "model" : "user", parts: parts }
        end

        # Gemini pairs a functionResponse to its call by NAME; a wrong name
        # silently mismatches, so a missing one fails loudly instead.
        def tool_turn(group, wire_ids = {})
          { role: "user", parts: group.map do |msg|
            unless msg.tool_name
              raise SchemaError, "Gemini tool results need tool_name to pair with their call"
            end

            key = msg.tool_error? ? "error" : "result"
            response = { name: msg.tool_name, response: { key => result_text(msg) } }
            response[:id] = wire_ids[msg.tool_call_id] if wire_ids[msg.tool_call_id]
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

        def native_tool_result?(message, origins)
          origins[message.tool_call_id] == :gemini
        end

        def tool_call_origins(history)
          history.each_with_object({}) do |message, origins|
            next unless message.assistant?

            message.tool_calls.each { |call| origins[call.id] = message.provider }
          end
        end

        def provider_call_ids(history)
          history.each_with_object({}) do |message, ids|
            next unless message.assistant? && message.provider == :gemini

            message.tool_calls.each do |call|
              ids[call.id] = call.provider_call_id if call.provider_call_id
            end
          end
        end

        def signed(part, signature, own)
          part[:thoughtSignature] = signature if own && signature
          part
        end
      end
    end
  end
end
