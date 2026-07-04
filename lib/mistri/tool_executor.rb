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

    def call(calls, tools_by_name, signal: nil, max_concurrency: 4)
      return [] if calls.empty?

      results = Array.new(calls.length)
      queue = Queue.new
      calls.each_with_index { |call, index| queue << [call, index] }
      workers = max_concurrency.clamp(1, calls.length)
      Array.new(workers) { worker(queue, results, tools_by_name, signal) }.each(&:join)
      calls.zip(results).map { |call, result| [call, result || INTERRUPTED] }
    end

    def worker(queue, results, tools_by_name, signal)
      Thread.new do
        loop do
          call, index = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          results[index] = signal&.aborted? ? INTERRUPTED : run_one(call, tools_by_name)
        end
      end
    end

    def run_one(call, tools_by_name)
      tool = tools_by_name[call.name]
      return "Error: unknown tool #{call.name.inspect}" unless tool

      with_rails_executor { tool.call(call.arguments) }
    rescue StandardError => e
      "Error running tool #{call.name.inspect}: #{e.class}: #{e.message}"
    end

    def with_rails_executor(&)
      executor = defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.executor
      executor ? executor.wrap(&) : yield
    end
  end
end
