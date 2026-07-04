# frozen_string_literal: true

module Mistri
  module Providers
    class Anthropic
      # Serializes protocol messages into Anthropic Messages API wire shapes.
      #
      # Wire rules that matter: consecutive tool results merge into one user
      # turn (parallel tool calls demand their results together), thinking
      # blocks replay with their signature and must never be altered, redacted
      # thinking replays as its opaque payload, and cache_control marks the
      # last system block and the last user message so the stable prefix and
      # the growing history both cache.
      module Serializer
        module_function

        def system_blocks(system, cache:)
          return nil if system.nil? || system.empty?

          blocks = [{ type: "text", text: system }]
          blocks.last[:cache_control] = { type: "ephemeral" } if cache
          blocks
        end

        def messages(history, cache: false)
          turns = history.reject(&:system?).chunk_while { |a, b| a.tool? && b.tool? }
          wire = turns.map do |group|
            group.first.tool? ? tool_results(group) : message(group.first)
          end
          mark_last_user_turn(wire) if cache
          wire
        end

        def tools(definitions)
          definitions.map do |tool|
            spec = tool.transform_keys(&:to_sym)
            wire = { name: spec[:name], description: spec[:description],
                     input_schema: spec[:input_schema] }
            wire[:eager_input_streaming] = true if spec[:eager_input_streaming]
            wire
          end
        end

        def message(msg)
          { role: msg.role.to_s, content: msg.content.map { |block| block(block) } }
        end

        def tool_results(group)
          { role: "user", content: group.map do |msg|
            { type: "tool_result", tool_use_id: msg.tool_call_id,
              content: msg.content.map { |block| block(block) } }
          end }
        end

        def block(block)
          case block
          when Content::Text then { type: "text", text: block.text }
          when Content::Thinking then thinking_block(block)
          when Content::Image
            { type: "image",
              source: { type: "base64", media_type: block.mime_type, data: block.data } }
          when ToolCall
            { type: "tool_use", id: block.id, name: block.name, input: block.arguments }
          else
            raise ArgumentError, "cannot serialize #{block.class} for Anthropic"
          end
        end

        def thinking_block(block)
          if block.redacted?
            { type: "redacted_thinking", data: block.signature }
          else
            { type: "thinking", thinking: block.thinking, signature: block.signature }
          end
        end

        def mark_last_user_turn(wire)
          last_user = wire.rindex { |turn| turn[:role] == "user" }
          return unless last_user

          content = wire[last_user][:content]
          return unless content.is_a?(Array) && content.any?

          content.last[:cache_control] =
            { type: "ephemeral" }
        end
      end
    end
  end
end
