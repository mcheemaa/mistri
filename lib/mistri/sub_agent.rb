# frozen_string_literal: true

module Mistri
  # Delegation with a clean context: a child agent runs on its own session
  # (the caller's store, linked in the caller's transcript), and only its
  # final answer returns to the parent; exploration never fills the
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
  # The open spawner never grants itself, preventing accidental recursion.
  # Hosts may deliberately nest fixed specialists. Several spawn calls in
  # one turn are scheduled concurrently; provider instances decide whether
  # their network requests overlap.
  #
  # Child events forward into the parent's stream tagged with origin
  # ("researcher#ab12cd34"; nesting of named specialists joins with ">").
  # Approval-gated tools cannot ride inside a child: a child answers its
  # parent synchronously and cannot fire-and-forget suspend, so statically
  # gated tools are refused at construction and a child that suspends at
  # runtime is denied and reported in band. Gate the delegation itself
  # instead (needs_approval: on the definition or spawner).
  class SubAgent
    require_relative "sub_agent/runtime"

    SPAWNER_DESCRIPTION =
      "Delegate a self-contained task to a focused child agent with a clean " \
      "context. The child starts blank: give it complete instructions and " \
      "every fact it needs. Use it to keep exploration out of your own " \
      "context, and spawn several in one turn to fan out independent " \
      "angles. Only the child's final answer comes back."

    attr_reader :name, :description

    # schema: makes the specialist answer in validated JSON (task mode
    # underneath), so fan-out children return a uniform shape the parent
    # synthesizes instead of five styles of prose.
    def initialize(name:, description:, provider:, system: nil, tools: [], schema: nil,
                   **agent_options)
      SubAgent.forbid_gated!(tools)
      @gate = agent_options.delete(:needs_approval) || false
      ChildAgentOptions.validate!(agent_options)
      @name = name.to_s
      @description = description
      @provider = provider
      @system = system
      @tools = tools
      @schema = schema
      @agent_options = agent_options
    end

    # The delegate tool: each call runs a fresh child and answers with its
    # final text, plus {agent, session_id} on the ui channel so a host can
    # link the child's transcript. The model may name each run, so two
    # parallel researchers read as "Corgi" and "Beagle" in lanes and lists
    # instead of "researcher" twice.
    def tool
      sub = self
      blurb = "#{@description} Runs as a focused sub-agent with a clean " \
              "context: give it complete instructions, it starts blank."
      Tool.define(@name, blurb, needs_approval: @gate,
                                schema: lambda {
                                  string :task, "Complete instructions for the sub-agent",
                                         required: true
                                  string :name, "A short name for this run, shown wherever " \
                                                "its events appear (default: the tool's name)"
                                }) do |args, context|
        sub.run_child(args.fetch("task"), context, name: args["name"])
      end
    end

    def run_child(task, context, name: nil)
      SubAgent.run_child(label: SubAgent.sanitize_label(name, fallback: @name),
                         provider: @provider, system: @system,
                         tools: @tools, task: task, parent_context: context, schema: @schema,
                         agent_options: @agent_options)
    end

    class << self
      # The open spawn tool: the model names each worker, grants it a tool
      # subset from the host's pool, and may pick a type, a model, and a
      # mode. All policy lives on Spawner; this is the front door.
      def spawner(provider:, **)
        Spawner.new(provider: provider, **).tool
      end

      # The whole kit in one call: the spawn tool plus the management
      # console, so a host hands its agent everything workers need.
      def pack(provider:, console: {}, **spawner_options)
        [spawner(provider: provider, **spawner_options), *Console.tools(**console)]
      end

      # A worker's display name, made safe for origins: the label rides
      # them as "label#id" and nesting joins with ">", so those separators
      # squeeze to hyphens along with whitespace. Blank falls back.
      def sanitize_label(text, fallback:)
        label = text.to_s.gsub(/[#>\s]+/, "-").squeeze("-")[0, 32]
        label = label.delete_prefix("-").delete_suffix("-")
        label.empty? ? fallback : label
      end

      def run_child(label:, provider:, system:, tools:, task:, parent_context:, schema: nil,
                    agent_options: {})
        ChildAgentOptions.validate!(agent_options)
        store = parent_context.session ? parent_context.session.store : Stores::Memory.new
        child = Session.new(store: store)
        parent_context.session&.append("subagent", "name" => label, "session_id" => child.id)
        # An inline child runs on a signal derived from the parent's: the
        # parent's abort cascades down through the handle, while stopping
        # the child alone leaves the parent running.
        signal, cascade = if parent_context.signal
                            parent_context.signal.derive
                          else
                            [AbortSignal.new, nil]
                          end
        result = begin
          execute_child(child: child, label: label, provider: provider, system: system,
                        tools: tools, task: task, schema: schema, signal: signal,
                        emit: parent_context.emit, agent_options: agent_options)
        rescue StandardError => e
          unless child.entries.any? { |entry| entry["type"] == Child::TERMINAL }
            child.append(Child::TERMINAL,
                         "status" => "failed", "error" => "#{e.class}: #{e.message}")
          end
          raise
        ensure
          parent_context.signal&.remove_callback(cascade) if cascade
        end
        outcome = answer(result, label, child)
        child.append(Child::TERMINAL, terminal(result))
        outcome
      end

      # The host job's way back in: a runtime factory turns the durable spec
      # into live dependencies inside the worker. The compatible direct
      # provider/system/tools form remains for hosts that already reconstruct
      # those values in their job. Either form is checked against the spec
      # before execution. The child then runs exactly like an inline child,
      # streams origin-tagged events, and reports back to its parent.
      #
      # The child lease is duplicate suppression, not an exactly-once claim:
      # a refused delivery leaves the current holder alone. A terminal means
      # a queued cancellation or finished retry and returns nil. The runner
      # retains an acquired lease through terminal persistence and reporting,
      # suppressing ordinary redelivery while that lease remains live.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- ordered dispatch transitions are the safety contract
      def run_dispatched(spec, store:, emit: nil, runtime_factory: nil,
                         provider: UNSET_RUNTIME_FIELD, system: UNSET_RUNTIME_FIELD,
                         tools: UNSET_RUNTIME_FIELD, schema: UNSET_RUNTIME_FIELD,
                         retry_factory_errors: true, **agent_options)
        runtime = nil
        resolved = nil
        authorized = false
        terminalize = false
        factory_failed = false
        retryable_exit = false
        primary_error = nil
        delivery_owned = false
        spec = RuntimeContract.own_spec(spec)
        RuntimeContract.validate_identity!(spec)
        child = Session.new(store: store, id: spec.fetch("session_id"))
        spec = RuntimeContract.bind_spec(child.entries, spec)
        authorized = true
        direct = { provider: provider, system: system, tools: tools, schema: schema,
                   agent_options: agent_options.empty? ? UNSET_RUNTIME_FIELD : agent_options }
        RuntimeContract.validate_resolution!(factory: runtime_factory, direct: direct)
        signal = AbortSignal.new
        terminalize = true
        delivery_owned = true
        lease = Locks.hold(Child.lease_key(child.id),
                           stop_key: Child.stop_key(child.id), signal: signal)
        if Mistri.locks && lease.nil?
          delivery_owned = false
          return nil
        end

        if Child.new(name: spec.fetch("name"), session_id: child.id, store: store).finished?
          return nil
        end

        child.append(Child::STARTED, {})
        RuntimeContract.validate_spec!(spec)
        signal.abort!("stopped by user") if Mistri.locks&.flag?(Child.stop_key(child.id))
        unless signal.aborted?
          runtime = RuntimeContract.resolve(spec, factory: runtime_factory, direct: direct) do
            factory_failed = true
          end
          resolved = RuntimeContract.validate_runtime!(runtime, spec)
          signal.abort!("stopped by user") if Mistri.locks&.flag?(Child.stop_key(child.id))
        end
        result = if signal.aborted?
                   Result.new(message: nil, status: :aborted)
                 else
                   execute_child(child: child, label: spec.fetch("name"),
                                 provider: resolved.provider, system: resolved.system,
                                 tools: resolved.tools, task: spec.fetch("task"),
                                 schema: resolved.schema, signal: signal, emit: emit,
                                 lease: lease, started: true,
                                 agent_options: resolved.agent_options)
                 end
        deny_pending(result, child)
        child.append(Child::TERMINAL, terminal(result))
        result
      rescue StandardError => e
        primary_error = e
        # Completion is a contract even when the runner dies in the
        # preamble: without this, a raise before the started entry (a lock
        # backend down, say) would leave the child reading :queued forever,
        # with nothing to report and nothing for a retry to heal.
        stopped = factory_failed && child_stop_requested?(child, signal)
        retryable = factory_failed && retry_factory_errors && !stopped
        retryable_exit = retryable
        if child && terminalize && !retryable &&
           !Child.new(name: spec.fetch("name"), session_id: child.id, store: store).finished?
          terminal = if stopped
                       { "status" => "stopped" }
                     else
                       { "status" => "failed", "error" => "#{e.class}: #{e.message}" }
                     end
          child.append(Child::TERMINAL, terminal)
        end
        raise
      ensure
        cleanup_error = RuntimeContract.cleanup(runtime)
        begin
          report_back(spec, store, emit) if child && authorized && delivery_owned
        ensure
          begin
            Mistri.locks&.clear_flag(Child.stop_key(child.id)) if child && lease && !retryable_exit
          ensure
            lease&.release
          end
        end
        raise cleanup_error if cleanup_error && primary_error.nil?
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      # A child cannot wait for a human, whichever door it entered by: any
      # calls parked for approval are denied AND settled with the denial as
      # their tool result, so no approval request stays open on a finished
      # child and its transcript replays without repair.
      def deny_pending(result, child)
        return unless result.awaiting_approval?

        result.pending.each do |call|
          child.deny(call.id, note: "sub-agents cannot pause for human approval")
          child.append_message(Message.tool(
                                 content: "Denied: sub-agents cannot pause for human approval.",
                                 tool_call_id: call.id, tool_name: call.name, tool_error: true
                               ))
        end
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

      def child_stop_requested?(child, signal)
        return false unless child

        signal&.aborted? || Mistri.locks&.flag?(Child.stop_key(child.id))
      end

      # A lease-backed runner reports before releasing the child lease. The
      # report joins the parent's inbox (a typed entry that folds at its next
      # turn boundary, exactly like a steer) and a :subagent_report event
      # closes the child's lane in whatever UI watched the spawn. A child
      # that never ran has nothing to say, and the parent session drops a
      # sequential duplicate delivery. Without locks, the host must serialize.
      def report_back(spec, store, emit)
        facade = Child.new(name: spec.fetch("name"), session_id: spec.fetch("session_id"),
                           store: store)
        return unless facade.finished?

        status = facade.status
        text = status == :failed ? facade.error : facade.report
        delivered = if (parent_id = spec["parent_session_id"])
                      Session.new(store: store, id: parent_id)
                             .deliver_report(name: facade.name, session_id: facade.session_id,
                                             status: status.to_s, text: text)
                    else
                      true
                    end
        return unless delivered

        emit&.call(Event.new(type: :subagent_report, agent: facade.name,
                             session_id: facade.session_id, status: status, content: text))
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
          deny_pending(result, child)
          ToolResult.new(content: "The #{label} sub-agent stopped: it needed human " \
                                  "approval, which sub-agents cannot wait for.", ui: link,
                         error: true)
        when :aborted
          ToolResult.new(content: "[the #{label} sub-agent was stopped]", ui: link, error: true)
        else
          reason = result.error_message || result.status
          ToolResult.new(content: "The #{label} sub-agent failed: #{reason}", ui: link,
                         error: true)
        end
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

require_relative "sub_agent/execution"
