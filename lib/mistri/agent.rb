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
  # carries on. A tool marked ends_turn ends the run once it executes: the
  # model does not get another word, and whatever comes next (a human's
  # answer to ask_user, say) arrives as the next run's input. Session#steer
  # queues a user message from any process while the loop runs; it folds
  # into the transcript at the next turn boundary, and a background child's
  # report arrives through the same inbox.
  class Agent # rubocop:disable Metrics/ClassLength -- lifecycle order is the class contract
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
      @budget.validate_provider!(@provider)
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

      fold_inbox # anything queued while this session sat idle arrived first; keep that order
      @session.append_message(Message.user_with_images(input, images))
      loop_turns(signal, output_schema, &emit)
    end

    # Continue a suspended run. Undecided approvals return immediately, still
    # suspended. Decided ones settle first: approved calls execute, denied
    # calls answer in band so the model knows and can react. Then the loop
    # carries on as if it never stopped, unless a settled call's tool ends
    # the turn, in which case its execution was the run's last word.
    def resume(signal: nil, &emit)
      open = @session.open_approvals
      pending = open.select { |approval| approval[:decision].nil? }
      if pending.any?
        return Result.new(message: nil, status: :awaiting_approval,
                          pending: pending.map { |approval| approval[:call] },
                          usage: Usage.zero)
      end

      executed = settle(open, signal, &emit)
      if executed.any? { |call| ends_turn?(call) }
        last = @session.messages.reverse_each.find(&:assistant?)
        return finished(last, Usage.zero, signal, handed_off: true)
      end

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
    # mid-task. A run an ends_turn tool ended returns as-is too: the floor
    # belongs to whoever answers, and re-prompting for JSON would steal it
    # back. Ask again once the answer arrives.
    def task(input, schema:, images: [], signal: nil, fixes: 1, &emit)
      result = run(TaskOutput.prompt(input, schema), images: images, signal: signal,
                                                     output_schema: schema, &emit)
      spent = result.usage
      fixes.downto(0) do |remaining|
        result = result.with(usage: spent)
        return result unless result.completed?
        return result if result.handed_off?

        value = TaskOutput.parse(result.text)
        errors = TaskOutput.errors(value, schema)
        return result.with(output: value) if errors.empty?
        raise SchemaError, "task output failed validation: #{errors.join("; ")}" if remaining.zero?

        result = run(TaskOutput.fix_prompt(errors), signal: signal, output_schema: schema, &emit)
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

        fold_inbox
        compacted = auto_compact(&emit)
        if compacted
          compaction_usage = compacted[:usage] || Usage.new
          validate_usage!(compaction_usage, kind: "compaction", &emit)
          usage += compaction_usage
          reason = @budget.exceeded(turns:, usage:, elapsed: monotonic_now - started)
          return stop_for_budget(reason, usage, &emit) if reason
        end
        last, turn_usage = run_turn(signal, output_schema, &emit)
        turns += 1
        usage += turn_usage

        # Any tool call the turn made must be answered or parked, or the
        # transcript is unpairable and replay fails.
        parked, ended = last.tool_calls? ? run_tools(last, signal, &emit) : [[], false]
        return suspended(last, parked, usage) if parked.any?
        return finished(last, usage, signal, handed_off: ended) if ended || done?(last, signal)
      end
    end

    # A steer or a child's report that lands while the model finishes
    # cleanly extends the run one more turn, so it is answered rather than
    # left dangling. Aborts, errors, and length stops always end the run;
    # the inbox stays pending for the next one.
    def done?(last, signal)
      return false if last.stop_reason == StopReason::TOOL_USE && !signal&.aborted?
      return true if signal&.aborted? || last.stop_reason != StopReason::STOP

      @session.pending_inbox.empty?
    end

    # Compact when the context has grown into the reserve. A failed
    # summarization skips quietly here: if the context genuinely no longer
    # fits, the next turn surfaces the real provider error.
    def auto_compact(&)
      return nil unless @compaction

      tokens = Compaction.context_tokens(@session.messages)
      return nil unless @compaction.needed?(tokens, context_window)

      Compactor.call(session: @session, provider: @provider, settings: @compaction, &)
    rescue CompactionError => e
      { usage: e.usage || Usage.new }
    end

    def context_window
      @compaction&.window || Models.find(@provider.model)&.context_window
    end

    # Materialize the inbox, queued steers and sub-agent reports alike, into
    # the transcript in arrival order. The folded message entry carries the
    # source entry's id under its marker key, which is what marks the entry
    # consumed: one append is both the fold and the marker, so a crash
    # between folds never double-delivers.
    def fold_inbox
      @session.pending_inbox.each do |entry|
        marker = Session::INBOX.fetch(entry["type"])
        @session.append("message", "message" => entry["message"], marker => entry["id"])
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
      usage = Usage.zero
      loop do
        held = nil
        gate = emit && ->(event) { event.terminal? ? held = event : emit.call(event) }
        message = @provider.stream(messages: history, system: @system,
                                   tools: @tools.map(&:spec), signal: signal,
                                   output_schema: output_schema, &gate)
        attempt_usage = message.usage || Usage.new
        validate_usage!(attempt_usage, message:, kind: "turn", &emit)
        usage += attempt_usage
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
        return [message, usage]
      end
    end

    def retry_turn?(error, attempt, signal)
      return false unless @retries && error
      return false if signal&.aborted?

      @retries.retry?(error, attempt)
    end

    def record_retry(message, error, attempt, pause, &emit)
      entry = { "attempt" => attempt, "error" => error, "delay" => pause.round(2) }
      entry["usage"] = (message.usage || Usage.new).to_h
      @session.append("retry", entry)
      note = format("attempt %<attempt>d failed; retrying in %<pause>.1fs",
                    attempt: attempt, pause: pause)
      emit&.call(Event.new(type: :retry, content: note, attempt: attempt,
                           max_attempts: @retries.attempts, delay: pause.round(2),
                           message: message))
    end

    def validate_usage!(usage, kind:, message: nil, &emit)
      @budget.validate_usage!(usage)
    rescue BudgetError => e
      entry = { "kind" => kind, "usage" => usage.to_h }
      entry["message"] = message.to_h if message
      @session.append("unpriced_attempt", entry)
      error = BudgetError.new(e.message, usage: e.usage || usage, provider_message: message)
      stopped = Message.assistant(content: "Run stopped: cost could not be determined.",
                                  stop_reason: StopReason::BUDGET,
                                  error_message: "budget_cost_unknown")
      @session.append_message(stopped)
      emit&.call(Event.new(type: :error, reason: StopReason::BUDGET, message: stopped,
                           error_message: error.message))
      raise error
    end

    # Backoff that an abort can cut short.
    def wait(seconds, signal)
      deadline = monotonic_now + seconds
      sleep(0.1) while monotonic_now < deadline && !signal&.aborted?
    end

    # Answer or park the assistant's tool calls. Ungated calls execute (only
    # on a genuine tool_use turn with no abort; otherwise they pair with
    # interrupted results). Gated calls park as approval requests. Nothing
    # is left dangling either way. Returns the parked calls and whether an
    # executed tool ends the turn; a parked call outranks an executed
    # ends_turn, because a suspension is the stronger stop and the model
    # regains the floor when the run resumes.
    def run_tools(assistant, signal, &emit)
      calls = assistant.tool_calls
      unless assistant.stop_reason == StopReason::TOOL_USE && !signal&.aborted?
        calls.each { |call| answer(call, ToolExecutor::INTERRUPTED, &emit) }
        return [[], false]
      end

      parked, free = screen(calls, signal, &emit).partition { |call| gated?(call) }
      executed = execute(free, signal, &emit)
      parked.each do |call|
        @session.append("approval_request", "call" => call.to_h)
        emit&.call(Event.new(type: :approval_needed, tool_call: call))
      end
      [parked, executed.any? { |call| ends_turn?(call) }]
    end

    # Returns the calls that actually executed (denied ones only answer).
    def settle(open, signal, &emit)
      approved, denied = open.partition { |approval| approval[:decision]["approved"] }
      cleared = screen(approved.map { |approval| approval[:call] }, signal, &emit)
      executed = execute(cleared, signal, &emit)
      denied.each do |approval|
        note = approval[:decision]["note"]
        text = "The user denied this tool call#{note ? ": #{note}" : "."}"
        answer(approval[:call], text, &emit)
      end
      executed
    end

    # Runs the calls and answers each; returns the calls that executed
    # (blocked and parked calls never reach here).
    def execute(calls, signal, &emit)
      return [] if calls.empty?

      results = ToolExecutor.call(calls, @tools_by_name, signal: signal,
                                                         max_concurrency: @max_concurrency,
                                                         session: @session, emit: emit,
                                                         app: @context)
      context = hook_context(signal, emit)
      results.each do |call, result, seconds|
        result = rewrite(call, result, context) if @after_tool
        answer(call, result, duration: seconds, &emit)
      end
      calls
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

    def ends_turn?(call)
      tool = @tools_by_name[call.name]
      tool ? tool.ends_turn? : false
    end

    # A run stopped during its tool phase ends with a clean assistant
    # message, so the message's stop reason alone would read :completed;
    # the signal is what knows the user stopped it. handed_off marks a run
    # an ends_turn tool ended, and only a genuinely completed one: a run
    # aborted during that same tool phase handed nothing to anyone.
    def finished(message, usage, signal = nil, handed_off: false)
      status = { StopReason::ABORTED => :aborted, StopReason::BUDGET => :budget,
                 StopReason::ERROR => :error }.fetch(message.stop_reason, :completed)
      status = :aborted if status == :completed && signal&.aborted?
      Result.new(message: message, status: status, usage: usage,
                 handed_off: handed_off && status == :completed)
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

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end # rubocop:enable Metrics/ClassLength
end
