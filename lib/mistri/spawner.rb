# frozen_string_literal: true

module Mistri
  # Host policy for spawning workers, as one object: the tool pool children
  # may draw from, the curated types, the model allowlist, the headcount
  # cap, and the dispatcher that makes background mode real. #tool builds
  # the spawn_agent tool the top-level agent holds; SubAgent.spawner and
  # SubAgent.pack are the front doors.
  #
  # Every policy violation answers the model in band (unknown type, missing
  # instructions, over capacity, workspace sharing in background mode);
  # only host configuration mistakes raise, and they raise at construction.
  class Spawner
    def initialize(provider:, tools: [], types: {}, models: [], max_children: 4,
                   dispatcher: nil, needs_approval: false, **agent_options)
      SubAgent.forbid_gated!(tools)
      if tools.any? { |tool| tool.name == "spawn_agent" }
        raise ConfigurationError, "the spawn tool never goes in its own pool"
      end

      @provider = provider
      @pool = tools
      # Symbol keys are natural Ruby; the wire speaks strings. One
      # normalization here and lookup, schema, and menu all agree.
      @types = types.transform_keys(&:to_s)
      @models = models
      @max_children = max_children
      @dispatcher = dispatcher
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

      if args["mode"] == "background" && @dispatcher
        if args["workspace"] == "parent"
          return "A worker sharing your workspace must run inline: a blocked parent " \
                 "cannot write concurrently, a working one can. Drop workspace or " \
                 "drop background."
        end

        return dispatch(args, worker, context)
      end

      SubAgent.run_child(label: label_for(args), provider: worker[:provider],
                         system: worker[:system], tools: worker[:tools],
                         task: args.fetch("task"), context: context, **@agent_options)
    end

    private

    # Create the child session and its lifecycle entries, hand the
    # dispatcher the serializable spec plus an in-process runner closing
    # over the reconstructed pieces, and answer with a truthful receipt:
    # what the child's status says after dispatch, not what the mode
    # promised. The runner closes over the spawn-time emit, so in-process
    # dispatchers keep streaming to whoever watched the spawn.
    def dispatch(args, worker, context)
      store = context.session ? context.session.store : Stores::Memory.new
      child = Session.new(store: store)
      label = label_for(args)
      context.session&.append("subagent", "name" => label, "session_id" => child.id)
      child.append(Child::DISPATCHED, {})
      spec = spec_for(args, worker, child, label, context)
      emit = context.emit
      options = @agent_options
      runner = lambda do
        SubAgent.run_dispatched(spec, provider: worker[:provider], system: worker[:system],
                                      tools: worker[:tools], store: store, emit: emit,
                                      **options)
      end
      @dispatcher.call(spec, runner)
      receipt(label, child, store)
    end

    def spec_for(args, worker, child, label, context)
      { "name" => label, "session_id" => child.id,
        "parent_session_id" => context.session&.id,
        "type" => args["type"] || "general-purpose",
        "instructions" => args["instructions"], "task" => args.fetch("task"),
        "tool_names" => worker[:tools].map(&:name),
        "model" => (worker[:provider].model if worker[:provider].respond_to?(:model)),
        "workspace" => args["workspace"] || "own" }
    end

    def receipt(label, child, store)
      status = Child.new(name: label, session_id: child.id, store: store).status
      state = if %i[running queued].include?(status)
                "is working in the background"
              else
                "already finished (#{status})"
              end
      ToolResult.new(
        content: "#{label} #{state} (agent id #{child.id[0, 8]}). Keep working: " \
                 "read_agent checks on it (wait: true blocks for its report), " \
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
      chosen = args["tools"].nil? || args["tools"].empty? ? definition.tool_names : args["tools"]
      { system: system, tools: pick(chosen),
        provider: typed_provider(args["model"], definition.model) }
    end

    def general_worker(args)
      system = args["instructions"].to_s
      if system.strip.empty?
        return "A general-purpose worker needs instructions: write its system prompt, " \
               "or pick a type."
      end

      { system: system, tools: pick(args["tools"]),
        provider: child_provider(args["model"]) }
    end

    # An explicit model choice goes through the allowlist; otherwise a
    # typed worker runs on its definition's model, and without one it
    # inherits the parent's provider. Host-curated definitions are
    # trusted the way the pool is.
    def typed_provider(requested, definition_model)
      return child_provider(requested) unless requested.to_s.empty?
      return @provider if definition_model.to_s.empty?

      Mistri.provider(definition_model)
    end

    def child_provider(requested)
      return @provider if requested.nil? || requested.to_s.empty?
      unless @models.include?(requested)
        raise ArgumentError,
              "model #{requested.inspect} is not allowed; available: #{@models.join(", ")}"
      end

      Mistri.provider(requested)
    end

    def over_capacity(session)
      return nil unless session

      busy = session.children.count { |child| %i[running queued].include?(child.status) }
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
      return @pool if names.nil? || names.empty?

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
          array :tools, "Subset of tools to grant (default: all, or the type's own list)",
                items: { type: "string", enum: pool_names }
        end
        string :model, "Model for the child#{fallback}", enum: models if models.any?
        if dispatcher
          string :mode, "inline blocks until the report; background returns a receipt " \
                        "now and you keep working (default: inline)",
                 enum: %w[inline background]
          string :workspace, "own gives the worker its own file space; parent shares " \
                             "yours and requires inline mode (default: own)",
                 enum: %w[own parent]
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
                "meanwhile: you get a receipt now, manage the worker with the console " \
                "tools, and collect its report with read_agent."
      end
      text
    end

    # The label rides origins as "label#id" and joins nesting with ">",
    # so those separators squeeze to hyphens along with whitespace.
    def label_for(args)
      label = args["name"].to_s.gsub(/[#>\s]+/, "-").squeeze("-")[0, 32]
      label = label.delete_prefix("-").delete_suffix("-")
      label.empty? ? "spawn" : label
    end
  end
end
