# frozen_string_literal: true

module Mistri
  # The agent loop: prompt the provider, run any tools it calls, feed the
  # results back, and repeat until it answers without calling tools. Every
  # streamed event reaches the caller's block as it arrives.
  #
  # Each message persists to the session the moment it completes, so a crash
  # or an abort leaves a replay-valid transcript with no repair step: an
  # aborted turn's unfinished tool calls get interrupted results before the
  # assistant turn is even stored, so tool_use and tool_result always pair.
  class Agent
    def initialize(provider:, session: nil, system: nil, tools: [], budget: nil,
                   max_concurrency: 4)
      @provider = provider
      @session = session || Session.new(store: Stores::Memory.new)
      @system = system
      @tools = tools
      @tools_by_name = tools.to_h { |tool| [tool.name, tool] }
      @budget = budget || Budget.new
      @max_concurrency = max_concurrency
    end

    attr_reader :session

    # Run one exchange to completion: append the user turn, then loop until the
    # model answers without tools, the run aborts, or a budget stops it.
    # Returns the final assistant message.
    def run(input, images: [], signal: nil, &emit)
      @session.append_message(Message.user_with_images(input, images))
      loop_turns(signal, &emit)
    end

    private

    def loop_turns(signal, &emit)
      turns = 0
      usage = Usage.zero
      last = nil
      loop do
        reason = @budget.exceeded(turns: turns, usage: usage)
        return stop_for_budget(reason, &emit) if reason

        last = run_turn(signal, &emit)
        turns += 1
        usage += last.usage if last.usage

        # Any tool call the turn made must be answered, even on an aborted or
        # truncated turn, or the transcript is unpairable and replay 400s.
        run_tools(last, signal, &emit) if last.tool_calls?
        return last if last.stop_reason != StopReason::TOOL_USE || signal&.aborted?
      end
    end

    def run_turn(signal, &)
      message = @provider.stream(messages: @session.messages, system: @system,
                                 tools: @tools.map(&:spec), signal: signal, &)
      @session.append_message(message)
      message
    end

    # Execute the assistant's tool calls and append their results as one paired
    # batch. When the signal is tripped, un-run calls still get interrupted
    # results, so the assistant turn is never left with a dangling tool_use.
    def run_tools(assistant, signal, &emit)
      results = ToolExecutor.call(assistant.tool_calls, @tools_by_name,
                                  signal: signal, max_concurrency: @max_concurrency)
      results.each do |call, result|
        message = Message.tool(content: result, tool_call_id: call.id, tool_name: call.name)
        @session.append_message(message)
        emit&.call(Event.new(type: :tool_result, tool_call: call, content: result_text(result)))
      end
    end

    def stop_for_budget(reason, &emit)
      message = Message.assistant(content: "Run stopped: #{reason} budget reached.",
                                  stop_reason: StopReason::ABORTED,
                                  error_message: "budget_#{reason}")
      @session.append_message(message)
      emit&.call(Event.new(type: :error, reason: StopReason::ABORTED, message: message,
                           error_message: "budget_#{reason}"))
      message
    end

    def result_text(result)
      result.is_a?(String) ? result : "[content]"
    end
  end
end
