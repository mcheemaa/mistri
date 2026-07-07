# frozen_string_literal: true

module Mistri
  # Delegation with a clean context: a child agent runs on its own session
  # (the caller's store, linked in the caller's transcript), and only its
  # final answer returns to the parent — exploration never fills the
  # parent's window. Compaction rescues a full context after the fact;
  # spawning avoids filling it in the first place. A child session is its
  # own single-provider session, so delegating to a cheaper model is the
  # sanctioned way to mix models.
  #
  # Two shapes on one mechanism. A named specialist the host curates:
  #
  #   researcher = Mistri::SubAgent.new(
  #     name: "researcher", description: "Answers factual questions.",
  #     provider: Mistri.provider("claude-haiku-4-5-20251001"),
  #     system: "Research. Report findings only.", tools: [fetch_page],
  #   )
  #   agent = Mistri::Agent.new(provider:, tools: [researcher.tool])
  #
  # and the open spawn tool, where the model composes each worker: names
  # it, writes its instructions, picks a tool subset, and may pick a model:
  #
  #   spawn = Mistri::SubAgent.spawner(provider:, tools: [fetch_page, search])
  #
  # Children never receive a spawn tool: delegation is one level deep by
  # construction. Parallel fan-out costs nothing — several spawn calls in
  # one turn run concurrently on the executor pool.
  #
  # Child events forward into the parent's stream tagged with origin
  # ("researcher#ab12cd34"; nesting of named specialists joins with ">").
  # Approval-gated tools cannot ride inside a child: a child answers its
  # parent synchronously and cannot fire-and-forget suspend, so statically
  # gated tools are refused at construction and a child that suspends at
  # runtime is denied and reported in band. Gate the delegation itself
  # instead (needs_approval: on the definition or spawner).
  class SubAgent
    SPAWNER_DESCRIPTION =
      "Delegate a self-contained task to a focused child agent with a clean " \
      "context. The child starts blank: give it complete instructions and " \
      "every fact it needs. Use it to keep exploration out of your own " \
      "context, and spawn several in one turn to fan out independent " \
      "angles. Only the child's final answer comes back."

    attr_reader :name, :description

    # schema: makes the specialist answer in validated JSON (task mode
    # underneath) — fan-out children then return a uniform shape the parent
    # synthesizes instead of five styles of prose.
    def initialize(name:, description:, provider:, system: nil, tools: [], schema: nil,
                   **agent_options)
      SubAgent.forbid_gated!(tools)
      @name = name.to_s
      @description = description
      @provider = provider
      @system = system
      @tools = tools
      @schema = schema
      @agent_options = agent_options
      @gate = agent_options.delete(:needs_approval) || false
    end

    # The delegate tool: each call runs a fresh child and answers with its
    # final text, plus {agent, session_id} on the ui channel so a host can
    # link the child's transcript.
    def tool
      sub = self
      blurb = "#{@description} Runs as a focused sub-agent with a clean " \
              "context: give it complete instructions, it starts blank."
      Tool.define(@name, blurb, needs_approval: @gate,
                                schema: lambda {
                                  string :task, "Complete instructions for the sub-agent",
                                         required: true
                                }) do |args, context|
        sub.run_child(args.fetch("task"), context)
      end
    end

    def run_child(task, context)
      SubAgent.run_child(label: @name, provider: @provider, system: @system,
                         tools: @tools, task: task, context: context, schema: @schema,
                         **@agent_options)
    end

    class << self
      # The open spawn tool over a pool of tools the host allows children to
      # use. The model may name the worker (a display label riding origins
      # and the transcript link) and grant a tool subset by name; models: is
      # the host's allowlist of child model ids — without one, no model
      # choice is offered at all, so a hallucinated id can never construct a
      # provider or land children on an expensive model.
      def spawner(provider:, tools: [], models: [], needs_approval: false, **agent_options)
        forbid_gated!(tools)
        if tools.any? { |tool| tool.name == "spawn_agent" }
          raise ConfigurationError, "the spawn tool never goes in its own pool"
        end

        schema = spawner_schema(tools, models, default_model(provider))
        Tool.define("spawn_agent", SPAWNER_DESCRIPTION,
                    needs_approval: needs_approval, schema: schema) do |args, context|
          run_child(label: child_label(args["name"]),
                    provider: child_provider(provider, args["model"], models),
                    system: args.fetch("instructions"),
                    tools: pick(tools, args["tools"]),
                    task: args.fetch("task"), context: context, **agent_options)
        end
      end

      def run_child(label:, provider:, system:, tools:, task:, context:, schema: nil,
                    **agent_options)
        store = context.session ? context.session.store : Stores::Memory.new
        child = Session.new(store: store)
        context.session&.append("subagent", "name" => label, "session_id" => child.id)
        # From the moment the link exists, every exit writes a terminal entry,
        # setup failures included, or the child would read as running forever.
        # The lease says "alive right now" to other processes; a child that
        # dies without its terminal reads :interrupted once it lapses.
        lease = Locks.hold(Child.lease_key(child.id))
        result = begin
          agent = Agent.new(provider: provider, session: child, system: system,
                            tools: tools, **agent_options)
          origin = "#{label}##{child.id[0, 8]}"
          emit = ->(event) { forward(event, origin, context) }
          if schema
            agent.task(task, schema: schema, signal: context.signal, &emit)
          else
            agent.run(task, signal: context.signal, &emit)
          end
        rescue StandardError => e
          child.append(Child::TERMINAL, "status" => "failed", "error" => "#{e.class}: #{e.message}")
          raise
        ensure
          lease&.release
        end
        outcome = answer(result, label, child)
        child.append(Child::TERMINAL, terminal(result))
        outcome
      end

      # Every child ends by writing its own terminal entry: completion is a
      # contract, and status stays readable from the store forever.
      def terminal(result)
        case result.status
        when :completed then { "status" => "done", "report" => result.text.to_s }
        when :aborted then { "status" => "stopped" }
        when :awaiting_approval
          { "status" => "failed",
            "error" => "needed human approval, which sub-agents cannot wait for" }
        else
          { "status" => "failed", "error" => (result.error_message || result.status).to_s }
        end
      end

      def forbid_gated!(tools)
        gated = tools.select { |tool| statically_gated?(tool) }
        return if gated.empty?

        raise ConfigurationError,
              "approval-gated tools cannot run inside a sub-agent " \
              "(#{gated.map(&:name).join(", ")}); gate the delegation instead"
      end

      private

      def forward(event, origin, context)
        return unless context.emit

        tagged = event.origin ? "#{origin}>#{event.origin}" : origin
        context.emit.call(event.with(origin: tagged))
      end

      # The parent always gets an in-band answer it can react to. A child
      # that suspends for approval is denied and abandoned: nothing else
      # will ever settle it.
      def answer(result, label, child)
        link = { "agent" => label, "session_id" => child.id }
        case result.status
        when :completed
          ToolResult.new(content: result.text.to_s, ui: link)
        when :awaiting_approval
          result.pending.each do |call|
            child.deny(call.id, note: "sub-agents cannot pause for human approval")
          end
          ToolResult.new(content: "The #{label} sub-agent stopped: it needed human " \
                                  "approval, which sub-agents cannot wait for.", ui: link)
        when :aborted
          ToolResult.new(content: "[the #{label} sub-agent was aborted]", ui: link)
        else
          reason = result.error_message || result.status
          ToolResult.new(content: "The #{label} sub-agent failed: #{reason}", ui: link)
        end
      end

      def pick(pool, names)
        return pool if names.nil? || names.empty?

        by_name = pool.to_h { |tool| [tool.name, tool] }
        names.map do |name|
          by_name.fetch(name) do
            raise ArgumentError,
                  "unknown tool #{name.inspect}; available: #{by_name.keys.join(", ")}"
          end
        end
      end

      def spawner_schema(pool, models, default)
        tool_names = pool.map(&:name)
        fallback = default ? " (default: #{default})" : ""
        lambda do
          string :name, "A short name for this worker, shown wherever its events appear"
          string :task, "The child's complete task", required: true
          string :instructions, "The child's system prompt", required: true
          if tool_names.any?
            array :tools, "Subset of tools to grant (default: all)",
                  items: { type: "string", enum: tool_names }
          end
          string :model, "Model for the child#{fallback}", enum: models if models.any?
        end
      end

      def default_model(provider)
        provider.model if provider.respond_to?(:model)
      end

      # The label rides origins as "label#id" and joins nesting with ">",
      # so those separators squeeze to hyphens along with whitespace.
      def child_label(raw)
        label = raw.to_s.gsub(/[#>\s]+/, "-").squeeze("-")[0, 32]
        label = label.delete_prefix("-").delete_suffix("-")
        label.empty? ? "spawn" : label
      end

      def child_provider(default, requested, models)
        return default if requested.nil? || requested.to_s.empty?
        unless models.include?(requested)
          raise ArgumentError,
                "model #{requested.inspect} is not allowed; available: #{models.join(", ")}"
        end

        Mistri.provider(requested)
      end

      # A predicate gate cannot be judged statically; the runtime denial in
      # answer covers it.
      def statically_gated?(tool)
        tool.needs_approval?({})
      rescue StandardError
        false
      end
    end
  end
end
