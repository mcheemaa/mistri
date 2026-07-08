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

      def run_child(label:, provider:, system:, tools:, task:, context:, schema: nil,
                    **agent_options)
        store = context.session ? context.session.store : Stores::Memory.new
        child = Session.new(store: store)
        context.session&.append("subagent", "name" => label, "session_id" => child.id)
        # An inline child runs on a signal derived from the parent's: the
        # parent's abort cascades down through the handle, while stopping
        # the child alone leaves the parent running.
        signal, cascade = context.signal ? context.signal.derive : [AbortSignal.new, nil]
        result = begin
          execute_child(child: child, label: label, provider: provider, system: system,
                        tools: tools, task: task, schema: schema, signal: signal,
                        emit: context.emit, **agent_options)
        ensure
          context.signal&.remove_callback(cascade) if cascade
        end
        outcome = answer(result, label, child)
        child.append(Child::TERMINAL, terminal(result))
        outcome
      end

      # The host job's way back in: reconstruct provider, system, and tools
      # from the spec through host registries, then hand them here. Reopens
      # the child session the spawn created, runs it exactly like an inline
      # child (started entry, lease, stop watching, terminals), streams
      # origin-tagged events to the emit the job supplies, and reports the
      # outcome back to the parent (see report_back). A background child
      # runs on its own signal: the parent's turn is long over, so only
      # stop_agent and the stop flag end it early.
      #
      # The child's lease is the exactly-once fence, so it is taken before
      # anything else: refused means another process is running this child
      # right now (a queue redelivered a live job) — leave its owner alone.
      # Holding it, a terminal decides: present means the child was
      # cancelled while queued or the queue retried a finished job, so
      # there is nothing to run; absent means run, and that includes the
      # child a crashed process left mid-run, which is exactly what queue
      # retries are for. Either kind of no-op returns nil.
      def run_dispatched(spec, provider:, system:, tools:, store:, emit: nil, schema: nil,
                         **agent_options)
        child = Session.new(store: store, id: spec.fetch("session_id"))
        signal = AbortSignal.new
        lease = Locks.hold(Child.lease_key(child.id),
                           stop_key: Child.stop_key(child.id), signal: signal)
        return nil if Mistri.locks && lease.nil?

        begin
          if Child.new(name: spec.fetch("name"), session_id: child.id, store: store).finished?
            lease&.release
            return nil
          end

          result = execute_child(child: child, label: spec.fetch("name"), provider: provider,
                                 system: system, tools: tools, task: spec.fetch("task"),
                                 schema: schema, signal: signal, emit: emit, lease: lease,
                                 **agent_options)
          deny_pending(result, child)
          child.append(Child::TERMINAL, terminal(result))
          result
        ensure
          report_back(spec, store, emit)
        end
      end

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
                                 tool_call_id: call.id, tool_name: call.name
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

      # The one hardened execution path every child goes through, whichever
      # door it entered by. From the started entry on, every exit writes a
      # terminal, setup failures included, or the child would read as
      # running forever. The lease says "alive right now" to other
      # processes and its thread watches the child's stop flag; a
      # dispatched run hands in the lease it already holds (its run-or-not
      # decision happened under the fence), an inline child acquires its
      # own here. Either way, this path releases it.
      def execute_child(child:, label:, provider:, system:, tools:, task:, schema:,
                        signal:, emit:, lease: nil, **agent_options)
        child.append(Child::STARTED, {})
        lease ||= Locks.hold(Child.lease_key(child.id),
                             stop_key: Child.stop_key(child.id), signal: signal)
        begin
          agent = Agent.new(provider: provider, session: child, system: system,
                            tools: tools, **agent_options)
          origin = "#{label}##{child.id[0, 8]}"
          tagged = ->(event) { forward(event, origin, emit) }
          if schema
            agent.task(task, schema: schema, signal: signal, &tagged)
          else
            agent.run(task, signal: signal, &tagged)
          end
        rescue StandardError => e
          child.append(Child::TERMINAL, "status" => "failed", "error" => "#{e.class}: #{e.message}")
          raise
        ensure
          lease&.release
          Mistri.locks&.clear_flag(Child.stop_key(child.id))
        end
      end

      def forward(event, origin, emit)
        return unless emit

        tagged = event.origin ? "#{origin}>#{event.origin}" : origin
        emit.call(event.with(origin: tagged))
      end

      # Every terminal outcome reports back, exactly once. The report joins
      # the parent's inbox — a typed entry that folds at its next turn
      # boundary, exactly like a steer — and a :subagent_report event
      # closes the child's lane in whatever UI watched the spawn. A child
      # that never ran has nothing to say, and the parent session drops a
      # duplicate delivery, so a redelivered job cannot repeat one.
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
                                  "approval, which sub-agents cannot wait for.", ui: link)
        when :aborted
          ToolResult.new(content: "[the #{label} sub-agent was stopped]", ui: link)
        else
          reason = result.error_message || result.status
          ToolResult.new(content: "The #{label} sub-agent failed: #{reason}", ui: link)
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
