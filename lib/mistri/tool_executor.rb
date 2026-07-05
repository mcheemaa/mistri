# frozen_string_literal: true

module Mistri
  # Runs a turn's tool calls and returns their results in the order the model
  # emitted them, regardless of completion order. Independent calls run
  # concurrently up to max_concurrency; each runs inside the Rails executor
  # when Rails is present, so ActiveRecord connections return to the pool.
  #
  # A tool that raises becomes an in-band error string the model can read. An
  # abort never starts a not-yet-started call: it gets an interrupted result
  # instead, so the turn always pairs and the session replays cleanly.
  module ToolExecutor
    INTERRUPTED = "[interrupted: this tool call never ran]"

    module_function

    def call(calls, tools_by_name, signal: nil, max_concurrency: 4, session: nil, emit: nil)
      return [] if calls.empty?

      context = ToolContext.new(session: session, signal: signal, emit: thread_safe(emit))
      results = Array.new(calls.length)
      queue = Queue.new
      calls.each_with_index { |call, index| queue << [call, index] }
      workers = max_concurrency.clamp(1, calls.length)
      Array.new(workers) { worker(queue, results, tools_by_name, context) }.each(&:join)
      calls.zip(results).map { |call, result| [call, result || INTERRUPTED] }
    end

    def worker(queue, results, tools_by_name, context)
      Thread.new do
        loop do
          call, index = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          interrupted = context.signal&.aborted?
          results[index] = interrupted ? INTERRUPTED : run_one(call, tools_by_name, context)
        end
      end
    end

    def run_one(call, tools_by_name, context)
      tool = tools_by_name[call.name]
      return "Error: unknown tool #{call.name.inspect}" unless tool

      with_rails_executor { tool.call(call.arguments, context) }
    rescue StandardError => e
      "Error running tool #{call.name.inspect}: #{e.class}: #{e.message}"
    end

    # Concurrent tools share the caller's sink; sinks are not required to be
    # thread-safe, so forwarded events serialize here.
    def thread_safe(emit)
      return nil unless emit

      mutex = Mutex.new
      ->(event) { mutex.synchronize { emit.call(event) } }
    end

    def with_rails_executor(&)
      executor = defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.executor
      executor ? executor.wrap(&) : yield
    end
  end
end
