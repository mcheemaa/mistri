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
          { role: msg.role.to_s, content: msg.content.filter_map { |block| block(block) } }
        end

        def tool_results(group)
          { role: "user", content: group.map do |msg|
            blocks = msg.content.filter_map { |block| block(block) }
            # The API rejects an empty tool_result; a space stands in for a
            # tool that returned nothing.
            blocks = [{ type: "text", text: " " }] if blocks.empty?
            result = { type: "tool_result", tool_use_id: msg.tool_call_id, content: blocks }
            result[:is_error] = true if msg.tool_error?
            result
          end }
        end

        # Returns nil for a block the API would reject (empty text, unusable
        # thinking), so callers filter_map it out.
        def block(block)
          case block
          when Content::Text then text_block(block)
          when Content::Thinking then thinking_block(block)
          when Content::Image
            { type: "image",
              source: { type: "base64", media_type: block.mime_type, data: block.data } }
          when ToolCall
            { type: "tool_use", id: block.id, name: block.name, input: block.arguments }
          else
            raise SchemaError, "cannot serialize #{block.class} for Anthropic"
          end
        end

        # The API rejects empty text content blocks.
        def text_block(block)
          block.text.empty? ? nil : { type: "text", text: block.text }
        end

        # Thinking replays only with its signature. Redacted thinking carries
        # its opaque payload; a normal thinking block missing its signature
        # (an aborted turn cut before signature_delta) cannot replay, so it
        # degrades to its text, or drops when even that is empty.
        def thinking_block(block)
          return { type: "redacted_thinking", data: block.signature } if block.redacted?
          if block.signature
            return { type: "thinking", thinking: block.thinking,
                     signature: block.signature }
          end

          block.thinking.empty? ? nil : { type: "text", text: block.thinking }
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
