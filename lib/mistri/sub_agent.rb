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
      #
      # types: is the host's registry of curated workers, Definition by
      # name: a typed child takes its system prompt, tools, and model from
      # the definition (instructions appends, explicit args override within
      # the pool and allowlist). "general-purpose" is always available: the
      # model writes that worker's system prompt itself. max_children caps
      # live workers per session; a spawn past the cap answers in band.
      def spawner(provider:, tools: [], types: {}, models: [], max_children: 4,
                  needs_approval: false, **agent_options)
        forbid_gated!(tools)
        if tools.any? { |tool| tool.name == "spawn_agent" }
          raise ConfigurationError, "the spawn tool never goes in its own pool"
        end

        # Symbol keys are natural Ruby; the wire speaks strings. One
        # normalization here and lookup, schema, and menu all agree.
        types = types.transform_keys(&:to_s)
        validate_types!(types, tools)

        schema = spawner_schema(tools, models, default_model(provider), types)
        Tool.define("spawn_agent", spawner_description(types),
                    needs_approval: needs_approval, schema: schema) do |args, context|
          crowded = over_capacity(context.session, max_children)
          next crowded if crowded

          worker = resolve_worker(args, types, tools, provider, models)
          next worker if worker.is_a?(String)

          run_child(label: child_label(args["name"]), provider: worker[:provider],
                    system: worker[:system], tools: worker[:tools],
                    task: args.fetch("task"), context: context, **agent_options)
        end
      end

      # The whole kit in one call: the spawn tool plus the management
      # console, so a host hands its agent everything workers need.
      def pack(provider:, console: {}, **spawner_options)
        [spawner(provider: provider, **spawner_options), *Console.tools(**console)]
      end

      def run_child(label:, provider:, system:, tools:, task:, context:, schema: nil,
                    **agent_options)
        store = context.session ? context.session.store : Stores::Memory.new
        child = Session.new(store: store)
        context.session&.append("subagent", "name" => label, "session_id" => child.id)
        # From the moment the link exists, every exit writes a terminal entry,
        # setup failures included, or the child would read as running forever.
        # The child runs on its own signal: the parent's abort cascades down
        # through the derived handle, while stopping the child alone leaves
        # the parent running. The lease says "alive right now" to other
        # processes and its thread watches the child's stop flag.
        signal, cascade = context.signal ? context.signal.derive : [AbortSignal.new, nil]
        lease = Locks.hold(Child.lease_key(child.id),
                           stop_key: Child.stop_key(child.id), signal: signal)
        result = begin
          agent = Agent.new(provider: provider, session: child, system: system,
                            tools: tools, **agent_options)
          origin = "#{label}##{child.id[0, 8]}"
          emit = ->(event) { forward(event, origin, context) }
          if schema
            agent.task(task, schema: schema, signal: signal, &emit)
          else
            agent.run(task, signal: signal, &emit)
          end
        rescue StandardError => e
          child.append(Child::TERMINAL, "status" => "failed", "error" => "#{e.class}: #{e.message}")
          raise
        ensure
          lease&.release
          context.signal&.remove_callback(cascade) if cascade
          Mistri.locks&.clear_flag(Child.stop_key(child.id))
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
          ToolResult.new(content: "[the #{label} sub-agent was stopped]", ui: link)
        else
          reason = result.error_message || result.status
          ToolResult.new(content: "The #{label} sub-agent failed: #{reason}", ui: link)
        end
      end

      # A worker's system prompt, tools, and provider, resolved from its
      # type; a String answers the model in band instead of raising.
      def resolve_worker(args, types, pool, parent_provider, models)
        type = args["type"].to_s
        return general_worker(args, pool, parent_provider, models) if type.empty? ||
                                                                      type == "general-purpose"

        definition = types[type]
        unless definition
          return "Unknown worker type #{type.inspect}; available: " \
                 "#{["general-purpose", *types.keys].join(", ")}."
        end

        system = [definition.render, args["instructions"]]
                 .reject { |part| part.to_s.strip.empty? }.join("\n\n")
        chosen = args["tools"].nil? || args["tools"].empty? ? definition.tool_names : args["tools"]
        { system: system, tools: pick(pool, chosen),
          provider: typed_provider(parent_provider, args["model"], models, definition.model) }
      end

      def general_worker(args, pool, parent_provider, models)
        system = args["instructions"].to_s
        if system.strip.empty?
          return "A general-purpose worker needs instructions: write its system prompt, " \
                 "or pick a type."
        end

        { system: system, tools: pick(pool, args["tools"]),
          provider: child_provider(parent_provider, args["model"], models) }
      end

      # An explicit model choice goes through the allowlist; otherwise a
      # typed worker runs on its definition's model, and without one it
      # inherits the parent's provider. Host-curated definitions are
      # trusted the way the pool is.
      def typed_provider(parent, requested, models, definition_model)
        return child_provider(parent, requested, models) unless requested.to_s.empty?
        return parent if definition_model.to_s.empty?

        Mistri.provider(definition_model)
      end

      def over_capacity(session, max_children)
        return nil unless session

        busy = session.children.count { |child| %i[running queued].include?(child.status) }
        return nil if busy < max_children

        "You already have #{busy} workers running; wait for one to finish or stop one."
      end

      # Types fail at construction, never mid-spawn: every definition must
      # render without vars (spawn types are self-contained prompts) and
      # declare only tools the pool actually carries.
      def validate_types!(types, pool)
        return if types.empty?
        if types.key?("general-purpose")
          raise ConfigurationError, "\"general-purpose\" is the built-in type; pick another name"
        end

        pool_names = pool.map(&:name)
        types.each do |name, definition|
          begin
            definition.render
          rescue ConfigurationError => e
            raise ConfigurationError,
                  "type #{name.inspect} cannot be a spawn type: #{e.message}"
          end
          missing = definition.tool_names - pool_names
          unless missing.empty?
            raise ConfigurationError,
                  "type #{name.inspect} declares tools the pool lacks: #{missing.join(", ")}"
          end
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

      def spawner_schema(pool, models, default, types = {})
        tool_names = pool.map(&:name)
        type_names = ["general-purpose", *types.keys]
        fallback = default ? " (default: #{default})" : ""
        lambda do
          string :name, "A short name for this worker, shown wherever its events appear"
          string :task, "The child's complete task", required: true
          if types.any?
            string :type, "The kind of worker (default: general-purpose)", enum: type_names
            string :instructions, "The worker's system prompt (required for " \
                                  "general-purpose; appended to a typed worker's own)"
          else
            string :instructions, "The child's system prompt", required: true
          end
          if tool_names.any?
            array :tools, "Subset of tools to grant (default: all, or the type's own list)",
                  items: { type: "string", enum: tool_names }
          end
          string :model, "Model for the child#{fallback}", enum: models if models.any?
        end
      end

      def spawner_description(types)
        return SPAWNER_DESCRIPTION if types.empty?

        "#{SPAWNER_DESCRIPTION} Typed workers come ready-made " \
          "(#{types.keys.join(", ")}): their instructions, tools, and model " \
          "are set; add instructions only to focus them. general-purpose " \
          "workers are yours to compose."
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
