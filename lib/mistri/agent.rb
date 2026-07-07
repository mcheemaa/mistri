# frozen_string_literal: true

require "json"

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
    # compaction defaults on so long sessions survive their context window;
    # pass false to disable, or a tuned Compaction. It only ever triggers
    # when the model's window is known (catalog or Compaction#window).
    # skills: an array of Skill (or a directory path for Skills.load). Their
    # descriptions join the system prompt and a read_skill tool serves full
    # bodies on demand.
    # before_tool and after_tool are the programmatic gates around every
    # execution: before_tool(call, context) blocks a call by returning the
    # reason as a String, which answers the model in band (and it runs again
    # when an approved call finally executes, so a decision that aged days
    # still passes current policy); after_tool(call, result, context) may
    # return a replacement result, or nil to keep the original.
    def initialize(provider:, session: nil, system: nil, tools: [], budget: nil,
                   max_concurrency: 4, transform_context: nil, compaction: Compaction.new,
                   retries: RetryPolicy.new, skills: [], before_tool: nil, after_tool: nil,
                   context: nil)
      @provider = provider
      @session = session || Session.new(store: Stores::Memory.new)
      skills = skills.is_a?(String) ? Skills.load(skills) : Array(skills)
      @system = Skills.amend(system, skills)
      @tools = skills.empty? ? tools : tools + [Skills.reader(skills)]
      @tools_by_name = @tools.to_h { |tool| [tool.name, tool] }
      raise ConfigurationError, "duplicate tool names" if @tools_by_name.length != @tools.length

      @budget = budget || Budget.new
      @max_concurrency = max_concurrency
      @transform_context = Array(transform_context)
      @compaction = compaction || nil
      @retries = retries || nil
      @before_tool = before_tool
      @after_tool = after_tool
      @context = context
    end

    attr_reader :session

    # Run one exchange: append the user turn, then loop until the model
    # answers without tools, a gated tool suspends the run, the run aborts,
    # or a budget stops it.
    # output_schema constrains every non-tool answer to JSON matching the
    # schema, natively where the provider supports it. task adds validation
    # on top; run alone does not validate.
    def run(input, images: [], signal: nil, output_schema: nil, &emit)
      if @session.open_approvals.any?
        raise ConfigurationError,
              "session is awaiting approvals; call resume"
      end
      if input.to_s.empty? && Array(images).empty?
        raise ArgumentError,
              "run needs input text or images"
      end

      fold_steers # steers queued while idle arrived first; keep that order
      @session.append_message(Message.user_with_images(input, images))
      loop_turns(signal, output_schema, &emit)
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
                          pending: pending.map { |approval| approval[:call] },
                          usage: Usage.zero)
      end

      settle(open, signal, &emit)
      loop_turns(signal, nil, &emit)
    end

    # Run an exchange that must end in a JSON value matching schema. Tools
    # run as usual; providers constrain the final answer natively where they
    # can, and the answer is validated here regardless. A violation goes
    # back to the model (fixes more times), then raises SchemaError. The
    # Result carries the validated value as output.
    #
    # A run that suspends for approval returns as-is: validation applies to
    # completed runs only, so resume the session and re-ask if that happens
    # mid-task.
    def task(input, schema:, images: [], signal: nil, fixes: 1, &emit)
      result = run(task_input(input, schema), images: images, signal: signal,
                                              output_schema: schema, &emit)
      spent = result.usage
      fixes.downto(0) do |remaining|
        result = result.with(usage: spent)
        return result unless result.completed?

        value = parse_output(result.text)
        errors = task_errors(value, schema)
        return result.with(output: value) if errors.empty?
        raise SchemaError, "task output failed validation: #{errors.join("; ")}" if remaining.zero?

        result = run(fix_prompt(errors), signal: signal, output_schema: schema, &emit)
        spent += result.usage
      end
    end

    # How full the context is: {tokens:, window:, fraction:}. Hosts render
    # meters and near-limit warnings from this; window is nil for models the
    # catalog does not know unless Compaction#window supplies one.
    def context_usage
      tokens = Compaction.context_tokens(@session.messages)
      window = context_window
      { tokens: tokens, window: window,
        fraction: window && (tokens.to_f / window).round(3) }
    end

    # Compact now (a UI button, a pre-flight trim before a big task). Returns
    # the Compactor result, or nil when there is nothing worth compacting.
    def compact(&)
      Compactor.call(session: @session, provider: @provider,
                     settings: @compaction || Compaction.new, &)
    end

    private

    def loop_turns(signal, output_schema = nil, &emit)
      turns = 0
      usage = Usage.zero
      started = monotonic_now
      loop do
        reason = @budget.exceeded(turns: turns, usage: usage, elapsed: monotonic_now - started)
        return stop_for_budget(reason, usage, &emit) if reason

        fold_steers
        compacted = auto_compact(&emit)
        usage += compacted[:usage] if compacted&.dig(:usage)
        last = run_turn(signal, output_schema, &emit)
        turns += 1
        usage += last.usage if last.usage

        # Any tool call the turn made must be answered or parked, or the
        # transcript is unpairable and replay fails.
        parked = last.tool_calls? ? run_tools(last, signal, &emit) : []
        return suspended(last, parked, usage) if parked.any?
        return finished(last, usage, signal) if done?(last, signal)
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

    # Compact when the context has grown into the reserve. A failed
    # summarization skips quietly here: if the context genuinely no longer
    # fits, the next turn surfaces the real provider error.
    def auto_compact(&)
      return nil unless @compaction

      tokens = Compaction.context_tokens(@session.messages)
      return nil unless @compaction.needed?(tokens, context_window)

      Compactor.call(session: @session, provider: @provider, settings: @compaction, &)
    rescue CompactionError
      nil
    end

    def context_window
      @compaction&.window || Models.find(@provider.model)&.context_window
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

    # transform_context reshapes what the model sees each turn (reminders,
    # redaction, windowing) without touching what the session stores. The
    # lambda gets the replay messages and returns the messages to send; it
    # must keep every tool call paired with its result or providers reject
    # the request.
    #
    # A transient failure retries the same request with backoff; the failed
    # attempt records as a retry entry, never as a message, and its terminal
    # (:done or :error) holds at a gate, so retries stay invisible to the
    # model and a recovered retry never shows the subscriber an error it
    # walks back. Only the accepted attempt persists and terminates.
    def run_turn(signal, output_schema = nil, &emit)
      history = @transform_context.reduce(@session.messages) do |messages, transform|
        transform.call(messages)
      end
      attempt = 0
      loop do
        held = nil
        gate = emit && ->(event) { event.terminal? ? held = event : emit.call(event) }
        message = @provider.stream(messages: history, system: @system,
                                   tools: @tools.map(&:spec), signal: signal,
                                   output_schema: output_schema, &gate)
        attempt += 1
        error = @retries&.error_for(message)
        if retry_turn?(error, attempt, signal)
          pause = @retries.delay(attempt, error["retry_after"])
          record_retry(message, error, attempt, pause, &emit)
          wait(pause, signal)
          next unless signal&.aborted?
        end
        emit&.call(held) if held
        @session.append_message(message)
        return message
      end
    end

    def retry_turn?(error, attempt, signal)
      return false unless @retries && error
      return false if signal&.aborted?

      @retries.retry?(error, attempt)
    end

    def record_retry(message, error, attempt, pause, &emit)
      @session.append("retry", "attempt" => attempt, "error" => error,
                               "delay" => pause.round(2))
      note = format("attempt %<attempt>d failed; retrying in %<pause>.1fs",
                    attempt: attempt, pause: pause)
      emit&.call(Event.new(type: :retry, content: note, attempt: attempt,
                           max_attempts: @retries.attempts, delay: pause.round(2),
                           message: message))
    end

    # Backoff that an abort can cut short.
    def wait(seconds, signal)
      deadline = monotonic_now + seconds
      sleep(0.1) while monotonic_now < deadline && !signal&.aborted?
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

      parked, free = screen(calls, signal, &emit).partition { |call| gated?(call) }
      execute(free, signal, &emit)
      parked.each do |call|
        @session.append("approval_request", "call" => call.to_h)
        emit&.call(Event.new(type: :approval_needed, tool_call: call))
      end
      parked
    end

    def settle(open, signal, &emit)
      approved, denied = open.partition { |approval| approval[:decision]["approved"] }
      cleared = screen(approved.map { |approval| approval[:call] }, signal, &emit)
      execute(cleared, signal, &emit)
      denied.each do |approval|
        note = approval[:decision]["note"]
        text = "The user denied this tool call#{note ? ": #{note}" : "."}"
        answer(approval[:call], text, &emit)
      end
    end

    def execute(calls, signal, &emit)
      return if calls.empty?

      results = ToolExecutor.call(calls, @tools_by_name, signal: signal,
                                                         max_concurrency: @max_concurrency,
                                                         session: @session, emit: emit,
                                                         app: @context)
      context = hook_context(signal, emit)
      results.each do |call, result, seconds|
        result = rewrite(call, result, context) if @after_tool
        answer(call, result, duration: seconds, &emit)
      end
    end

    # A blocked call answers in band, so the model reads the reason and
    # reacts; a hook that raises blocks conservatively rather than letting
    # an unpoliced call through.
    def screen(calls, signal, &emit)
      return calls unless @before_tool

      context = hook_context(signal, emit)
      calls.reject do |call|
        reason = begin
          @before_tool.call(call, context)
        rescue StandardError => e
          "the before_tool hook failed: #{e.class}: #{e.message}"
        end
        next false unless reason.is_a?(String)

        answer(call, "Blocked: #{reason}", &emit)
        true
      end
    end

    def rewrite(call, result, context)
      @after_tool.call(call, result, context) || result
    rescue StandardError => e
      "Error in after_tool hook: #{e.class}: #{e.message}"
    end

    def hook_context(signal, emit)
      ToolContext.new(session: @session, signal: signal, emit: emit, app: @context)
    end

    # The tool message carries both channels; the :tool_result event exposes
    # it whole so hosts read event.message.ui for their side of the result.
    def answer(call, result, duration: nil, &emit)
      content, ui = result.is_a?(ToolResult) ? [result.content, result.ui] : [result, nil]
      message = @session.append_message(Message.tool(content: content, tool_call_id: call.id,
                                                     tool_name: call.name, ui: ui))
      text = content.is_a?(String) ? content : "[content]"
      emit&.call(Event.new(type: :tool_result, tool_call: call, content: text,
                           message: message, duration: duration))
    end

    def gated?(call)
      tool = @tools_by_name[call.name]
      tool ? tool.needs_approval?(call.arguments) : false
    end

    # A run stopped during its tool phase ends with a clean assistant
    # message, so the message's stop reason alone would read :completed;
    # the signal is what knows the user stopped it.
    def finished(message, usage, signal = nil)
      status = { StopReason::ABORTED => :aborted, StopReason::BUDGET => :budget,
                 StopReason::ERROR => :error }.fetch(message.stop_reason, :completed)
      status = :aborted if status == :completed && signal&.aborted?
      Result.new(message: message, status: status, usage: usage)
    end

    def suspended(message, parked, usage)
      Result.new(message: message, status: :awaiting_approval, pending: parked, usage: usage)
    end

    def stop_for_budget(reason, usage, &emit)
      message = Message.assistant(content: "Run stopped: #{reason} budget reached.",
                                  stop_reason: StopReason::BUDGET,
                                  error_message: "budget_#{reason}")
      @session.append_message(message)
      emit&.call(Event.new(type: :error, reason: StopReason::BUDGET, message: message,
                           error_message: "budget_#{reason}"))
      Result.new(message: message, status: :budget, usage: usage)
    end

    # Distinguishable from a parsed nil: JSON "null" is a valid value.
    PARSE_FAILED = Object.new.freeze
    private_constant :PARSE_FAILED

    def task_input(input, schema)
      "#{input}\n\nAnswer with ONLY a JSON value matching this schema:\n" \
        "#{JSON.generate(Schema.strict(schema))}"
    end

    def parse_output(text)
      body = text.to_s.strip
      body = body[/\A```(?:json)?\s*(.*?)```\z/m, 1] || body
      JSON.parse(body)
    rescue JSON::ParserError
      PARSE_FAILED
    end

    def task_errors(value, schema)
      return ["the answer is not valid JSON"] if value.equal?(PARSE_FAILED)

      Schema.violations(value, schema)
    end

    def fix_prompt(errors)
      lines = errors.map { |error| "- #{error}" }.join("\n")
      "Your answer did not satisfy the required output schema. Problems:\n" \
        "#{lines}\nReply with ONLY the corrected JSON."
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
