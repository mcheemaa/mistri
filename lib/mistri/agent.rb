# frozen_string_literal: true

module Mistri
  # The agent loop: prompt the provider, run any tools it calls, feed the
  # results back, and repeat until it answers without calling tools. Every
  # streamed event reaches the caller's block as it arrives, and every run
  # returns a Result.
  #
  # Each message persists to the session the moment it completes, so a crash
  # or an abort leaves a replay-valid transcript with no repair step. A tool
  # marked needs_approval suspends the run instead of executing: the run
  # returns at once (no thread ever waits on a human), the decision arrives
  # later as a session entry from any process, and resume settles it and
  # carries on. Session#steer queues a user message from any process while
  # the loop runs; it folds into the transcript at the next turn boundary.
  class Agent
    def initialize(provider:, session: nil, system: nil, tools: [], budget: nil,
                   max_concurrency: 4)
      @provider = provider
      @session = session || Session.new(store: Stores::Memory.new)
      @system = system
      @tools = tools
      @tools_by_name = tools.to_h { |tool| [tool.name, tool] }
      raise ConfigurationError, "duplicate tool names" if @tools_by_name.length != tools.length

      @budget = budget || Budget.new
      @max_concurrency = max_concurrency
    end

    attr_reader :session

    # Run one exchange: append the user turn, then loop until the model
    # answers without tools, a gated tool suspends the run, the run aborts,
    # or a budget stops it.
    def run(input, images: [], signal: nil, &emit)
      if @session.open_approvals.any?
        raise ConfigurationError, "session is awaiting approval decisions; call resume"
      end
      if input.to_s.empty? && Array(images).empty?
        raise ArgumentError, "run needs input text or images"
      end

      fold_steers # steers queued while idle arrived first; keep that order
      @session.append_message(Message.user_with_images(input, images))
      loop_turns(signal, &emit)
    end

    # Continue a suspended run. Undecided approvals return immediately, still
    # suspended. Decided ones settle first: approved calls execute, denied
    # calls answer in band so the model knows and can react. Then the loop
    # carries on as if it never stopped.
    def resume(signal: nil, &emit)
      open = @session.open_approvals
      pending = open.select { |approval| approval[:decision].nil? }
      if pending.any?
        return Result.new(message: nil, status: :awaiting_approval,
                          pending: pending.map { |approval| approval[:call] })
      end

      settle(open, signal, &emit)
      loop_turns(signal, &emit)
    end

    private

    def loop_turns(signal, &emit)
      turns = 0
      usage = Usage.zero
      started = monotonic_now
      loop do
        reason = @budget.exceeded(turns: turns, usage: usage, elapsed: monotonic_now - started)
        return stop_for_budget(reason, &emit) if reason

        fold_steers
        last = run_turn(signal, &emit)
        turns += 1
        usage += last.usage if last.usage

        # Any tool call the turn made must be answered or parked, or the
        # transcript is unpairable and replay fails.
        parked = last.tool_calls? ? run_tools(last, signal, &emit) : []
        return suspended(last, parked) if parked.any?
        return finished(last) if done?(last, signal)
      end
    end

    # A steer that lands while the model finishes cleanly extends the run one
    # more turn so it gets answered. Aborts, errors, and length stops always
    # end the run; the steer stays pending for the next one.
    def done?(last, signal)
      return false if last.stop_reason == StopReason::TOOL_USE && !signal&.aborted?
      return true if signal&.aborted? || last.stop_reason != StopReason::STOP

      @session.pending_steers.empty?
    end

    # Materialize queued steers into the transcript in arrival order. The
    # folded message entry carries the steer id, which is what marks the steer
    # consumed: one append is both the fold and the marker, so a crash between
    # steers never double-delivers.
    def fold_steers
      @session.pending_steers.each do |steer|
        @session.append("message", "message" => steer["message"], "steer_id" => steer["id"])
      end
    end

    def run_turn(signal, &)
      message = @provider.stream(messages: @session.messages, system: @system,
                                 tools: @tools.map(&:spec), signal: signal, &)
      @session.append_message(message)
      message
    end

    # Answer or park the assistant's tool calls. Ungated calls execute (only
    # on a genuine tool_use turn with no abort; otherwise they pair with
    # interrupted results). Gated calls park as approval requests and are
    # returned, so the loop can suspend. Nothing is left dangling either way.
    def run_tools(assistant, signal, &emit)
      calls = assistant.tool_calls
      unless assistant.stop_reason == StopReason::TOOL_USE && !signal&.aborted?
        calls.each { |call| answer(call, ToolExecutor::INTERRUPTED, &emit) }
        return []
      end

      parked, free = calls.partition { |call| gated?(call) }
      execute(free, signal, &emit)
      parked.each do |call|
        @session.append("approval_request", "call" => call.to_h)
        emit&.call(Event.new(type: :approval_needed, tool_call: call))
      end
      parked
    end

    def settle(open, signal, &emit)
      approved, denied = open.partition { |approval| approval[:decision]["approved"] }
      execute(approved.map { |approval| approval[:call] }, signal, &emit)
      denied.each do |approval|
        note = approval[:decision]["note"]
        text = "The user denied this tool call#{note ? ": #{note}" : "."}"
        answer(approval[:call], text, &emit)
      end
    end

    def execute(calls, signal, &emit)
      return if calls.empty?

      results = ToolExecutor.call(calls, @tools_by_name,
                                  signal: signal, max_concurrency: @max_concurrency)
      results.each { |call, result| answer(call, result, &emit) }
    end

    def answer(call, result, &emit)
      @session.append_message(Message.tool(content: result, tool_call_id: call.id,
                                           tool_name: call.name))
      text = result.is_a?(String) ? result : "[content]"
      emit&.call(Event.new(type: :tool_result, tool_call: call, content: text))
    end

    def gated?(call)
      tool = @tools_by_name[call.name]
      tool ? tool.needs_approval?(call.arguments) : false
    end

    def finished(message)
      status = { StopReason::ABORTED => :aborted, StopReason::BUDGET => :budget,
                 StopReason::ERROR => :error }.fetch(message.stop_reason, :completed)
      Result.new(message: message, status: status)
    end

    def suspended(message, parked)
      Result.new(message: message, status: :awaiting_approval, pending: parked)
    end

    def stop_for_budget(reason, &emit)
      message = Message.assistant(content: "Run stopped: #{reason} budget reached.",
                                  stop_reason: StopReason::BUDGET,
                                  error_message: "budget_#{reason}")
      @session.append_message(message)
      emit&.call(Event.new(type: :error, reason: StopReason::BUDGET, message: message,
                           error_message: "budget_#{reason}"))
      Result.new(message: message, status: :budget)
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
