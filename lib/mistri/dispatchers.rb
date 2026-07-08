# frozen_string_literal: true

module Mistri
  # How a background child actually executes. The spawn tool hands every
  # dispatcher two things: the serializable spec (name, session_id,
  # parent_session_id, type, instructions, tool_names, model, workspace,
  # task) and a runner closure that executes the child in this process with
  # everything already reconstructed.
  #
  # In-process dispatchers just call the runner. A queue dispatcher ignores
  # the runner, enqueues the spec, and its job reconstructs the pieces from
  # host registries and calls SubAgent.run_dispatched:
  #
  #   dispatcher: ->(spec, _runner) { ChildRunJob.perform_async(spec) }
  #
  # The runner closes over the spawn-time event sink, so in-process
  # children keep streaming to whoever watched the spawn; that sink must
  # outlive the parent's turn (a broadcast lambda does, a request-scoped
  # object may not).
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
      def call(_spec, runner)
        ::Thread.new do
          runner.call
        rescue StandardError
          # The runner writes terminals for its own failures; a thread must
          # never die loudly into the process.
          nil
        end
        nil
      end
    end
  end
end
