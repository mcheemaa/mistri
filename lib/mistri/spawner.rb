# frozen_string_literal: true

module Mistri
  # Host policy for spawning workers, as one object: the tool pool children
  # may draw from, the curated types, the model allowlist, the headcount
  # cap, and the dispatcher that makes background mode real. A host runtime
  # factory reconstructs live dependencies after the dispatch boundary;
  # model text never chooses or proves resource isolation. #tool builds the
  # spawn_agent tool the top-level agent holds; SubAgent.spawner and
  # SubAgent.pack are the front doors.
  #
  # Every policy violation answers the model in band (unknown type, missing
  # instructions, over capacity); only host configuration mistakes raise,
  # and they raise at construction.
  class Spawner
    def initialize(provider:, tools: [], types: {}, models: [], max_children: 4,
                   dispatcher: nil, runtime_factory: nil, needs_approval: false,
                   **agent_options)
      tools = Array.new(tools) if tools.is_a?(Array)
      models = Array.new(models) if models.is_a?(Array)
      ChildAgentOptions.validate!(agent_options)
      validate_configuration!(tools, models, dispatcher, runtime_factory)

      @provider = provider
      @pool = tools.freeze
      # Symbol keys are natural Ruby; the wire speaks strings. One
      # normalization here and lookup, schema, and menu all agree.
      @types = types.transform_keys(&:to_s).freeze
      @models = models.map { |model| String.new(model).freeze }.freeze
      @max_children = max_children
      @dispatcher = dispatcher
      @runtime_factory = runtime_factory
      @needs_approval = needs_approval
      @agent_options = agent_options
      validate_types!
    end

    def tool
      spawner = self
      Tool.define("spawn_agent", description, needs_approval: @needs_approval,
                                              schema: schema) do |args, context|
        spawner.spawn(args, context)
      end
    end

    def spawn(args, context)
      crowded = over_capacity(context.session)
      return crowded if crowded

      worker = resolve_worker(args)
      return worker if worker.is_a?(String)

      return dispatch(args, worker, context) if args["mode"] == "background" && @dispatcher

      SubAgent.run_child(label: label_for(args), provider: provider_for(worker),
                         system: worker[:system], tools: worker[:tools],
                         task: args.fetch("task"), parent_context: context,
                         agent_options: @agent_options)
    end

    private

    def validate_configuration!(tools, models, dispatcher, runtime_factory)
      validate_tool_pool!(tools)
      validate_models!(models)
      validate_dispatcher!(dispatcher, runtime_factory)
    end

    def validate_tool_pool!(tools)
      unless tools.is_a?(Array) && tools.all?(Tool)
        raise ConfigurationError, "the spawn tool pool must contain only Mistri::Tool instances"
      end

      SubAgent.forbid_gated!(tools)
      if tools.any? { |tool| tool.name == "spawn_agent" }
        raise ConfigurationError, "the spawn tool never goes in its own pool"
      end
      return if tools.map(&:name).uniq.length == tools.length

      raise ConfigurationError, "the spawn tool pool has duplicate tool names"
    end

    def validate_models!(models)
      unless models.is_a?(Array) &&
             models.all? { |model| model.is_a?(String) && !model.empty? }
        raise ConfigurationError, "the spawn model allowlist must contain non-empty strings"
      end
      return if models.uniq.length == models.length

      raise ConfigurationError, "the spawn model allowlist has duplicate model names"
    end

    def validate_dispatcher!(dispatcher, runtime_factory)
      if dispatcher && !dispatcher.respond_to?(:call)
        raise ConfigurationError, "dispatcher must be callable"
      end
      if dispatcher && !runtime_factory.respond_to?(:call)
        raise ConfigurationError,
              "a dispatcher requires runtime_factory: to reconstruct background children"
      end
      return unless runtime_factory && !dispatcher

      raise ConfigurationError, "runtime_factory: requires a dispatcher"
    end

    # Create the child session and its lifecycle entries, hand the
    # dispatcher the serializable spec plus an in-process runner that calls
    # the host factory inside the worker, and answer with a truthful receipt:
    # what the child's status says after dispatch, not what the mode
    # promised. The runner closes over the spawn-time emit, so in-process
    # dispatchers keep streaming to whoever watched the spawn.
    def dispatch(args, worker, context)
      store = context.session ? context.session.store : Stores::Memory.new
      child = Session.new(store: store)
      label = label_for(args)
      spec = spec_for(args, worker, child, label, context)
      context.session&.append("subagent", "name" => label, "session_id" => child.id)
      child.append(Child::DISPATCHED, "spec" => spec)
      emit = context.emit
      runtime_factory = @runtime_factory
      runner = lambda do
        SubAgent.run_dispatched(spec, runtime_factory: runtime_factory,
                                      store: store, emit: emit,
                                      retry_factory_errors: false)
      end
      @dispatcher.call(spec, runner)
      receipt(label, child, store)
    end

    def spec_for(args, worker, child, label, context)
      model = worker[:model]
      unless model.is_a?(String) && !model.empty?
        raise ConfigurationError,
              "a background child provider must expose a non-empty model identity"
      end
      spec = { "spec_version" => SubAgent::DISPATCH_SPEC_VERSION,
               "name" => label, "session_id" => child.id,
               "parent_session_id" => context.session&.id,
               "type" => args["type"] || "general-purpose",
               "instructions" => args["instructions"], "task" => args.fetch("task"),
               "tool_names" => worker[:tools].map(&:name),
               "model" => model }
      owned, error = ToolArguments.canonicalize(spec)
      return owned unless error

      raise ConfigurationError, "background child spec is not bounded JSON"
    end

    def receipt(label, child, store)
      status = Child.new(name: label, session_id: child.id, store: store).status
      state = if %i[running queued].include?(status)
                "is working in the background"
              else
                "already finished (#{status})"
              end
      ToolResult.new(
        content: "#{label} #{state} (agent id #{child.id[0, 8]}). Keep working: its " \
                 "report will arrive in your context when it finishes. Meanwhile " \
                 "read_agent checks on it (wait: true blocks for the report), " \
                 "steer_agent adjusts it, stop_agent stops it.",
        ui: { "agent" => label, "session_id" => child.id, "mode" => "background" }
      )
    end

    # A worker's system prompt, tools, and provider, resolved from its
    # type; a String answers the model in band instead of raising.
    def resolve_worker(args)
      type = args["type"].to_s
      return general_worker(args) if type.empty? || type == "general-purpose"

      definition = @types[type]
      unless definition
        return "Unknown worker type #{type.inspect}; available: " \
               "#{["general-purpose", *@types.keys].join(", ")}."
      end

      system = [definition.render, args["instructions"]]
               .reject { |part| part.to_s.strip.empty? }.join("\n\n")
      chosen = args["tools"].nil? ? definition.tool_names : args["tools"]
      { system: system, tools: pick(chosen),
        **provider_choice(args["model"], definition.model) }
    end

    def general_worker(args)
      system = args["instructions"].to_s
      if system.strip.empty?
        return "A general-purpose worker needs instructions: write its system prompt, " \
               "or pick a type."
      end

      { system: system, tools: pick(args["tools"]), **provider_choice(args["model"]) }
    end

    # A background grant needs only a stable model identity; constructing
    # its live provider belongs to the worker factory. Inline execution turns
    # the same choice into a provider immediately before the child starts.
    def provider_choice(requested, definition_model = nil)
      if requested.nil? || requested.to_s.empty?
        return { model: definition_model } unless definition_model.to_s.empty?

        model = @provider.model if @provider.respond_to?(:model)
        return { provider: @provider, model: model }
      end
      unless @models.include?(requested)
        raise ArgumentError,
              "model #{requested.inspect} is not allowed; available: #{@models.join(", ")}"
      end

      { model: requested }
    end

    def provider_for(worker)
      worker[:provider] || Mistri.provider(worker.fetch(:model))
    end

    def over_capacity(session)
      return nil unless session

      busy = session.children.count { |child| Child::LIVE.include?(child.status) }
      return nil if busy < @max_children

      "You already have #{busy} workers running; wait for one to finish or stop one."
    end

    # Types fail at construction, never mid-spawn: every definition must
    # render without vars (spawn types are self-contained prompts) and
    # declare only tools the pool actually carries.
    def validate_types!
      return if @types.empty?
      if @types.key?("general-purpose")
        raise ConfigurationError, "\"general-purpose\" is the built-in type; pick another name"
      end

      pool_names = @pool.map(&:name)
      @types.each do |name, definition|
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

    def pick(names)
      return @pool if names.nil?
      if names.uniq.length != names.length
        raise ArgumentError, "tool selections cannot contain duplicate names"
      end

      by_name = @pool.to_h { |tool| [tool.name, tool] }
      names.map do |name|
        by_name.fetch(name) do
          raise ArgumentError,
                "unknown tool #{name.inspect}; available: #{by_name.keys.join(", ")}"
        end
      end
    end

    def schema
      pool_names = @pool.map(&:name)
      type_names = ["general-purpose", *@types.keys]
      types = @types
      models = @models
      dispatcher = @dispatcher
      default = @provider.model if @provider.respond_to?(:model)
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
        if pool_names.any?
          array :tools, "Exact tools to grant (omit for all, or the type's own list; " \
                        "an empty list grants none)",
                items: { type: "string", enum: pool_names }, uniqueItems: true
        end
        string :model, "Model for the child#{fallback}", enum: models if models.any?
        if dispatcher
          string :mode, "inline blocks until the report; background returns a receipt " \
                        "now and you keep working (default: inline)",
                 enum: %w[inline background]
        end
      end
    end

    def description
      text = SubAgent::SPAWNER_DESCRIPTION
      unless @types.empty?
        text += " Typed workers come ready-made (#{@types.keys.join(", ")}): their " \
                "instructions, tools, and model are set; add instructions only to " \
                "focus them. general-purpose workers are yours to compose."
      end
      if @dispatcher
        text += " Use background mode when the work is long and you can keep helping " \
                "meanwhile: you get a receipt now, its report arrives on its own when " \
                "the worker finishes, and the console tools manage it in between."
      end
      text
    end

    def label_for(args)
      SubAgent.sanitize_label(args["name"], fallback: "spawn")
    end
  end
end
