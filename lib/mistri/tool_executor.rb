# frozen_string_literal: true

require "timeout"

module Mistri
  # Runs a turn's tool calls and returns their results in the order the model
  # emitted them, regardless of completion order. Independent calls run
  # concurrently up to max_concurrency; each runs inside the Rails executor
  # when Rails is present, so ActiveRecord connections return to the pool.
  #
  # A tool that fails becomes an in-band ToolResult with an explicit error
  # fact. An abort never starts a not-yet-started call: it gets an interrupted
  # result instead, so the turn always pairs and the session replays cleanly.
  module ToolExecutor
    # Separates Mistri's deadline from a handler's own Timeout::Error.
    class InvocationTimeout < StandardError
    end
    private_constant :InvocationTimeout

    INTERRUPTED = "[interrupted: this tool call never ran]"
    OUTCOME_UNKNOWN = "[interrupted: this tool call's outcome is unavailable; the tool may have " \
                      "executed, so verify its effects before retrying]"
    VERIFY_BEFORE_RETRY = "The tool may have completed partially; verify its effects before " \
                          "retrying."
    COMMITTED = Object.new.freeze
    private_constant :COMMITTED

    PreparedContext = Class.new(ToolContext) do
      def arguments_prepared? = true
    end
    private_constant :PreparedContext

    module_function

    def call(calls, tools_by_name, signal: nil, max_concurrency: 4, session: nil, emit: nil,
             app: nil)
      call_with_outcomes(
        calls,
        tools_by_name,
        signal:,
        max_concurrency:,
        session:,
        emit:,
        app:,
        prepared_arguments: false
      ).map { |call, result, seconds, _committed| [call, result, seconds] }
    end

    # Agent prepares model arguments before approval and execution. This
    # lower-level form preserves that boundary and exposes commitment so hooks
    # cannot run for queued calls that an abort prevented from starting.
    def call_with_outcomes(calls, tools_by_name, signal: nil, max_concurrency: 4, session: nil,
                           emit: nil, app: nil, prepared_arguments: false)
      return [] if calls.empty?

      delivery = EventDelivery.wrap(emit, passthrough: [InvocationTimeout])
      context_class = prepared_arguments ? PreparedContext : ToolContext
      context = context_class.new(session: session, signal: signal,
                                  emit: thread_safe(delivery, signal), app: app)
      results = Array.new(calls.length)
      queue = Queue.new
      errors = Queue.new
      calls.each_with_index { |call, index| queue << [call, index] }
      workers = max_concurrency.clamp(1, calls.length)
      Array.new(workers) { worker(queue, results, tools_by_name, context, errors) }.each(&:join)
      unless errors.empty?
        error = errors.pop
        raise EventDelivery.unwrap(error, delivery)
      end

      calls.each_with_index.map do |call, index|
        entry = results[index]
        entry = [failure(OUTCOME_UNKNOWN), nil, true] if entry.equal?(COMMITTED)
        value, seconds, committed = entry || [failure(INTERRUPTED), nil, false]
        [call, value, seconds, committed]
      end
    end

    def worker(queue, results, tools_by_name, context, errors)
      Thread.new do
        loop do
          break unless errors.empty?

          call, index = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          if context.signal&.aborted?
            results[index] = [failure(INTERRUPTED), nil, false]
            next
          end

          results[index] = run_one(call, index, results, tools_by_name, context)
        end
      rescue StandardError => e
        errors << e
      end
    end

    def run_one(call, index, results, tools_by_name, context)
      tool = tools_by_name[call.name]
      return [failure("Error: unknown tool #{call.name.inspect}"), nil, false] unless tool

      return [failure(INTERRUPTED), nil, false] unless commit(call, context)

      results[index] = COMMITTED
      [*invoke_one(tool, call, context), true]
    end

    def invoke_one(tool, call, context)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = with_rails_executor { invoke(tool, call, context) }
      [value, elapsed(started)]
    rescue EventDelivery::Failure
      raise
    rescue InvocationTimeout
      content = "Error running tool #{call.name.inspect}: timed out after #{tool.timeout}s. " \
                "#{VERIFY_BEFORE_RETRY}"
      [failure(content), elapsed(started)]
    rescue StandardError => e
      [failure("Error running tool #{call.name.inspect}: #{e.class}: #{e.message}. " \
               "#{VERIFY_BEFORE_RETRY}"),
       elapsed(started)]
    end

    def invoke(tool, call, context)
      return tool.call(call.arguments, context) unless tool.timeout

      Timeout.timeout(tool.timeout, InvocationTimeout) do
        tool.call(call.arguments, context)
      end
    end

    def commit(call, context)
      return false if context.signal&.aborted?
      return true unless context.emit

      context.emit.call(Event.new(type: :tool_started, tool_call: call))
    end

    def failure(content) = ToolResult.new(content:, error: true)

    def elapsed(started)
      started && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    # Concurrent tools share the caller's sink; sinks are not required to be
    # thread-safe, so forwarded events serialize here.
    def thread_safe(delivery, signal)
      return nil unless delivery

      mutex = Mutex.new
      # Already-committed workers may report after a sibling fails delivery;
      # give all of them the first failure without calling the broken sink.
      failure = nil
      lambda do |event|
        mutex.synchronize do
          next false if event.type == :tool_started && (failure || signal&.aborted?)
          raise failure if failure

          result = begin
            delivery.call(event)
          rescue InvocationTimeout
            raise
          rescue EventDelivery::Failure => e
            failure = e
            raise
          end
          event.type == :tool_started ? true : result
        end
      end
    end

    def with_rails_executor(&)
      executor = defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.executor
      executor ? executor.wrap(&) : yield
    end
  end
end
