# frozen_string_literal: true

module Mistri
  # How a background child actually executes. The spawn tool hands every
  # dispatcher two things: a versioned serializable spec (name, session_id,
  # parent_session_id, type, instructions, tool_names, model, task) and a
  # runner closure that invokes the host runtime factory inside this process.
  #
  # In-process dispatchers just call the runner. A queue dispatcher ignores
  # the runner, enqueues the spec, and its job reconstructs the pieces from
  # host registries and calls SubAgent.run_dispatched:
  #
  #   dispatcher: ->(spec, _runner) { ChildRunJob.perform_async(spec) }
  #
  # The runner invokes the host factory inside the worker and keeps the
  # spawn-time event sink. In-process children stream to whoever watched the
  # spawn; that sink must outlive the parent's turn (a broadcast lambda does,
  # a request-scoped object may not) and hears from the worker's thread,
  # concurrently with the parent's own events. The gem's sinks tolerate that;
  # a custom one must too.
  module Dispatchers
    # Runs the child synchronously inside the spawn call and still answers
    # in receipt form: background degrades gracefully where no concurrency
    # exists (consoles, tests), and the receipt stays truthful because it
    # reads the child's status after dispatch.
    class Inline
      def call(_spec, runner) = runner.call
    end

    # Real in-process background: the child runs on its own thread and the
    # spawn call returns immediately. Enough for development and for hosts
    # whose children are short; queue-backed hosts plug their own lambda.
    class Thread
      def call(spec, runner)
        ::Thread.new do
          runner.call
        rescue StandardError => e
          # Execution failures have a durable terminal before re-raising;
          # cleanup may raise after a successful terminal. Neither should
          # make a thread die loudly or disappear without a diagnostic.
          warn "mistri: background runner for #{spec["name"].inspect} crashed: " \
               "#{e.class}: #{e.message}"
        end
        nil
      end
    end
  end
end
