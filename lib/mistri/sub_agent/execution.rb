# frozen_string_literal: true

module Mistri
  class SubAgent
    class << self
      # The hardened execution path every child uses. Inline work acquires
      # and cleans up its lease here; a dispatched owner supplies its lease
      # and retains it through terminal persistence and parent reporting.
      def execute_child(child:, label:, provider:, system:, tools:, task:, schema:,
                        signal:, emit:, lease: nil, started: false, agent_options: {})
        ChildAgentOptions.validate!(agent_options)
        child.append(Child::STARTED, {}) unless started
        owns_lease = lease.nil?
        primary_error = nil
        begin
          lease ||= Locks.hold(Child.lease_key(child.id),
                               stop_key: Child.stop_key(child.id), signal: signal)
          abort_before_child_start!(child, signal, lease)
          if signal.aborted?
            Result.new(message: nil, status: :aborted)
          else
            run_child_agent(child:, label:, provider:, system:, tools:, task:, schema:,
                            signal:, emit:, agent_options:)
          end
        rescue StandardError => e
          primary_error = e
          child.append(Child::TERMINAL, "status" => "failed", "error" => "#{e.class}: #{e.message}")
          raise
        ensure
          cleanup_error = release_inline_lease(child, lease) if owns_lease
          raise cleanup_error if cleanup_error && primary_error.nil?
        end
      end

      def release_inline_lease(child, lease)
        errors = []
        begin
          lease&.release
        rescue StandardError => e
          errors << e
        end
        begin
          Mistri.locks&.clear_flag(Child.stop_key(child.id))
        rescue StandardError => e
          errors << e
        end
        errors.first
      end

      def abort_before_child_start!(child, signal, lease)
        return unless Mistri.locks
        return if lease && !Mistri.locks.flag?(Child.stop_key(child.id))

        signal.abort!("stopped by user")
      end

      def run_child_agent(child:, label:, provider:, system:, tools:, task:, schema:,
                          signal:, emit:, agent_options:)
        agent = Agent.new(provider: provider, session: child, system: system,
                          tools: tools, **agent_options)
        origin = "#{label}##{child.id[0, 8]}"
        tagged = ->(event) { forward(event, origin, emit) }
        return agent.task(task, schema: schema, signal: signal, &tagged) if schema

        agent.run(task, signal: signal, &tagged)
      end

      def forward(event, origin, emit)
        return unless emit

        tagged = event.origin ? "#{origin}>#{event.origin}" : origin
        emit.call(event.with(origin: tagged))
      end

      private :abort_before_child_start!, :execute_child, :forward,
              :release_inline_lease, :run_child_agent
    end
  end
end
