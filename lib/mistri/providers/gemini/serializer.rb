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
      # never replay.
      module Serializer
        module_function

        def contents(history)
          turns = history.reject(&:system?).chunk_while { |a, b| a.tool? && b.tool? }
          turns.filter_map { |group| group.first.tool? ? tool_turn(group) : turn(group.first) }
        end

        def system_instruction(system)
          return nil if system.nil? || system.empty?

          { parts: [{ text: system }] }
        end

        def tools(definitions)
          declarations = definitions.map do |tool|
            spec = tool.transform_keys(&:to_sym)
            { name: spec[:name], description: spec[:description],
              parameters: spec[:input_schema] }
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
        def tool_turn(group)
          { role: "user", parts: group.map do |msg|
            unless msg.tool_name
              raise SchemaError, "Gemini tool results need tool_name to pair with their call"
            end

            { functionResponse: { name: msg.tool_name,
                                  response: { "result" => result_text(msg) } } }
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
              signed({ functionCall: { name: block.name, args: block.arguments } },
                     block.signature, own)
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
