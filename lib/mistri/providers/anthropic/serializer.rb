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
      # the growing history both cache. A deferred tool travels with
      # defer_loading, which keeps it out of the prompt, and a result that
      # loads one carries a tool_reference to it.
      module Serializer
        # The first deferred definition in a conversation rebuilds its cached
        # prefix. This one is sent from the first request, so a load never
        # does. No result references it, so it never enters the prompt.
        RESERVED = { name: "mistri_deferred_tools",
                     description: "Reserved. Keeps tool loading in place. Never call it.",
                     input_schema: { type: "object", properties: {}.freeze }.freeze,
                     defer_loading: true }.freeze
        private_constant :RESERVED

        module_function

        def system_blocks(system, cache:)
          return nil if system.nil? || system.empty?

          blocks = [{ type: "text", text: system }]
          blocks.last[:cache_control] = { type: "ephemeral" } if cache
          blocks
        end

        # deferred names the deferred tools of this request: only those can
        # be referenced, and the API refuses a reference to any other.
        # system_messages sends each reminder as a system message. Without it
        # a reminder is text of a user turn.
        def messages(history, cache: false, deferred: [], system_messages: false)
          unreferenced = deferred.dup
          history = results_first(history)
          history = Reminder.as_user_turns(history) unless system_messages
          wire = []
          held = []
          history.chunk_while { |a, b| a.tool? && b.tool? }.each do |group|
            first = group.first
            next (held << first if first.reminder) if first.system?

            turn = first.tool? ? tool_results(group, unreferenced) : message(first)
            next unless turn

            wire.concat(system_turns(held, wire.last)) if first.assistant?
            wire << turn
          end
          wire.concat(system_turns(held, wire.last))
          mark_last_user_turn(wire) if cache
          wire
        end

        # A system message stored among the results of one turn follows them,
        # so the results of parallel calls stay one user turn.
        def results_first(history)
          history.chunk_while { |a, b| (a.tool? || a.system?) && (b.tool? || b.system?) }
                 .flat_map { |run| run.partition(&:tool?).flatten(1) }
        end

        # The API takes a system message after a user turn, and before an
        # assistant turn or at the end. A reminder stored anywhere else is
        # sent there. When no user turn precedes that place, it is sent as
        # text of a user turn.
        def system_turns(held, before)
          reminders = held.slice!(0..)
          unless before && before[:role] == "user"
            return Reminder.as_user_turns(reminders).filter_map { |msg| message(msg) }
          end

          reminders.filter_map do |reminder|
            blocks = reminder.content.grep(Content::Text).filter_map { |text| text_block(text) }
            { role: "system", content: blocks } if blocks.any?
          end
        end

        # deferred is nil for an agent that defers nothing, and the loaded
        # deferred tools for one that does.
        def tools(definitions, deferred = nil)
          eager = definitions.map { |tool| definition(tool) }
          return eager unless deferred

          loaded = deferred.map { |tool| definition(tool).merge(defer_loading: true) }
          if (eager + loaded).any? { |tool| tool[:name] == RESERVED[:name] }
            raise ConfigurationError, "the tool name #{RESERVED[:name]} is reserved while " \
                                      "tools are deferred on Anthropic"
          end

          eager + [RESERVED] + loaded
        end

        # The names a result may reference: the deferred tools of the request,
        # never the reserved definition.
        def referable(definitions)
          definitions.filter_map do |tool|
            tool[:name] if tool[:defer_loading] && !tool.equal?(RESERVED)
          end
        end

        def definition(tool)
          spec = tool.transform_keys(&:to_sym)
          wire = { name: spec[:name], description: spec[:description],
                   input_schema: spec[:input_schema] }
          wire[:eager_input_streaming] = true if spec[:eager_input_streaming]
          wire
        end

        # The API rejects a user turn with no content.
        def message(msg)
          own = msg.provider == :anthropic
          blocks = msg.content.filter_map { |content| block(content, own:) }
          { role: msg.role.to_s, content: blocks } unless msg.user? && blocks.empty?
        end

        # The API takes references alone in a tool_result, so the result's own
        # content follows the results of the turn.
        def tool_results(group, unreferenced = [])
          after = []
          results = group.map do |msg|
            blocks = msg.content.filter_map { |content| block(content, own: false) }
            references = references(msg, unreferenced)
            if references.any?
              after.concat(blocks)
              blocks = references
            end
            # The API rejects an empty tool_result; a space stands in for a
            # tool that returned nothing.
            blocks = [{ type: "text", text: " " }] if blocks.empty?
            result = { type: "tool_result", tool_use_id: msg.tool_call_id, content: blocks }
            result[:is_error] = true if msg.tool_error?
            result
          end
          { role: "user", content: results + after }
        end

        # A failed result must be text alone. The API adds a tool's definition
        # to the prompt at every reference, so only the first result that
        # loads a tool references it: its name is then removed from
        # unreferenced.
        def references(msg, unreferenced)
          return [] if msg.tool_error?

          names = msg.loads.to_a & unreferenced
          unreferenced.reject! { |name| names.include?(name) }
          names.map { |name| { type: "tool_reference", tool_name: name } }
        end

        # Returns nil for a block the API would reject (empty text, unusable
        # thinking), so callers filter_map it out.
        def block(block, own: true)
          case block
          when Content::Text then text_block(block)
          when Content::Thinking then thinking_block(block, own:)
          when Content::Image
            { type: "image",
              source: { type: "base64", media_type: block.mime_type, data: block.data } }
          when ToolCall
            { type: "tool_use", id: block.id, name: block.name,
              input: ToolArguments.replay_object(block) }
          else
            raise SchemaError, "cannot serialize #{block.class} for Anthropic"
          end
        end

        # The API rejects a turn whose text is only whitespace.
        def text_block(block)
          block.text.match?(/\A[[:space:]]*\z/) ? nil : { type: "text", text: block.text }
        end

        # Thinking replays only with its signature. Redacted thinking carries
        # its opaque payload; a normal thinking block missing its signature
        # (an aborted turn cut before signature_delta) cannot replay, so it
        # degrades to its text, or drops when even that is empty.
        def thinking_block(block, own: true)
          return { type: "redacted_thinking", data: block.signature } if own && block.redacted?
          if own && block.signature
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
