# frozen_string_literal: true

require "json"

module Mistri
  module Providers
    class OpenAI
      # Serializes protocol messages into Responses API input items.
      #
      # Replay pairing is the rule that matters: with store: false the full
      # history resends every turn, and a reasoning item must return VERBATIM
      # (its encrypted_content is the model's chain of thought) followed by
      # the same items it originally preceded. The signature slots carry what
      # pairing needs: Thinking.signature holds the whole reasoning item,
      # Text.signature the message item id, ToolCall.signature the
      # function_call item id.
      #
      # A result that loads deferred tools is followed by an additional_tools
      # item, which makes them callable from that point on and leaves the
      # request's own tools, and so the cached prefix, as they were.
      module Serializer
        module_function

        # The deferred tools are only indexed by name here. One is converted
        # to a definition when a result loads it, not on every request.
        def input_items(history, deferred: [])
          specs = deferred.to_h { |tool| [tool[:name] || tool["name"], tool] }
          declared = {}
          history.reject(&:system?).flat_map do |msg|
            items = items_for(msg, declared)
            msg.tool? ? items + additions(msg, specs, declared) : items
          end
        end

        def additions(msg, specs, declared)
          return [] if msg.tool_error?

          fresh = msg.loads.to_a.uniq.select { |name| specs.key?(name) && !declared.key?(name) }
          return [] if fresh.empty?

          fresh.each { |name| declared[name] = true }
          [{ type: "additional_tools", role: "developer", tools: tools(specs.values_at(*fresh)) }]
        end

        # Left unset, the API makes each schema strict, which makes every
        # optional field required, and the model then invents their values.
        def tools(definitions)
          definitions.map do |tool|
            spec = tool.transform_keys(&:to_sym)
            { type: "function", name: spec[:name], description: spec[:description],
              parameters: spec[:input_schema], strict: false }
          end
        end

        def items_for(msg, declared = {})
          case msg.role
          when :user then [user_item(msg)]
          when :tool then [tool_result_item(msg)]
          when :assistant then assistant_items(msg, declared)
          else []
          end
        end

        def user_item(msg)
          { role: "user", content: msg.content.map { |block| user_block(block) } }
        end

        def user_block(block)
          case block
          when Content::Text then { type: "input_text", text: block.text }
          when Content::Image
            { type: "input_image", image_url: "data:#{block.mime_type};base64,#{block.data}" }
          else
            raise SchemaError, "cannot serialize #{block.class} for OpenAI user input"
          end
        end

        # Non-text blocks in a tool result have no function_call_output
        # encoding; note the omission rather than dropping it silently.
        def tool_result_item(msg)
          omitted = msg.content.count { |block| !block.is_a?(Content::Text) }
          text = msg.text.to_s
          text = "#{text}\n[#{omitted} non-text block(s) omitted]".strip if omitted.positive?
          { type: "function_call_output", call_id: msg.tool_call_id, output: text }
        end

        def assistant_items(msg, declared = {})
          own = msg.provider == :openai
          msg.content.filter_map { |block| assistant_item(block, own:, declared:) }
        end

        def assistant_item(block, own: true, declared: {})
          case block
          when Content::Thinking then reasoning_item(block, own:)
          when Content::Text then message_item(block, own:)
          when ToolCall then function_call_item(block, own:, declared:)
          end
        end

        # The reasoning item replays exactly as it arrived or not at all. An
        # item without encrypted_content triggers a server-side id lookup that
        # cannot succeed under store: false, so it drops rather than 404s.
        def reasoning_item(block, own: true)
          return nil unless own && block.signature

          item = JSON.parse(block.signature)
          item.is_a?(Hash) && item["encrypted_content"] ? item : nil
        rescue JSON::ParserError
          nil
        end

        def message_item(block, own: true)
          item = { type: "message", role: "assistant",
                   content: [{ type: "output_text", text: block.text }] }
          item[:id] = block.signature if own && block.signature
          item
        end

        # A tool that came through additional_tools sits in a namespace of its
        # own name. gpt-5.4 and gpt-5.5 refuse a call to it without one, and
        # every model takes one, whoever made the call.
        def function_call_item(block, own: true, declared: {})
          item = { type: "function_call", call_id: block.id, name: block.name,
                   arguments: JSON.generate(ToolArguments.replay_value(block)) }
          item[:namespace] = block.name if declared.key?(block.name)
          item[:id] = block.signature if own && block.signature && !block.arguments_error
          item
        end
      end
    end
  end
end
