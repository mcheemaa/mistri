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
    MAX_ARGUMENT_VIOLATIONS = 8
    MAX_ARGUMENT_ERROR_BYTES = 2048
    MAX_VIOLATION_SOURCE_BYTES = 4096
    TOOL_ARGUMENT_VALIDATOR = Tool.instance_method(:validate_arguments)
    private_constant :MAX_ARGUMENT_VIOLATIONS, :MAX_ARGUMENT_ERROR_BYTES,
                     :MAX_VIOLATION_SOURCE_BYTES, :TOOL_ARGUMENT_VALIDATOR

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

      @tool_specs, @external_tool_validators = compile_tool_contracts

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
      if refresh_tool_control.any?
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
      open = refresh_tool_control
      pending = open.select { |approval| approval[:decision].nil? }
      if pending.any?
        return Result.new(message: nil, status: :awaiting_approval,
                          pending: pending.map { |approval| approval[:call] },
                          usage: Usage.zero)
      end

      executed = settle(open, signal, &emit)
      if signal&.aborted?
        last = @session.messages.reverse_each.find(&:assistant?)
        return finished(last, Usage.zero, signal)
      end
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
      plan = Schema.task_plan(schema)
      result = run(
        TaskOutput.prompt(input, plan), images:, signal:, output_schema: plan, &emit
      )
      spent = result.usage
      fixes.downto(0) do |remaining|
        result = result.with(usage: spent)
        return result unless result.completed?
        return result if result.handed_off?

        value = TaskOutput.parse(result.text)
        errors = TaskOutput.errors(value, plan)
        return result.with(output: value) if errors.empty?
        raise SchemaError, "task output failed validation: #{errors.join("; ")}" if remaining.zero?

        result = run(TaskOutput.fix_prompt(errors), signal:, output_schema: plan, &emit)
        spent += result.usage
      end
    end

    # How full the context is: {tokens:, window:, fraction:}. Hosts render
    # meters and near-limit warnings from this; window is nil for models the
    # catalog does not know unless Compaction#window supplies one.
    def context_usage
      tokens = @session.context_tokens
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

      tokens = @session.context_tokens
      return nil unless @compaction.needed?(tokens, context_window,
                                            max_output: Models.shared_output(@provider.model))

      compact_automatically(&)
    end

    def compact_automatically(&emit)
      delivery = EventDelivery.wrap(emit)
      Compactor.call(session: @session, provider: @provider, settings: @compaction, &delivery)
    rescue EventDelivery::Failure => e
      raise EventDelivery.unwrap(e, delivery)
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
      schema = provider_output_schema(output_schema)
      loop do
        held = nil
        gate = emit && ->(event) { event.terminal? ? held = event : emit.call(event) }
        message = @provider.stream(messages: history, system: @system,
                                   tools: @tool_specs, signal: signal,
                                   output_schema: schema, &gate)
        message, held = enforce_tool_call_envelope(message, held)
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
        reserve_tool_call_ids(message.tool_calls)
        return [message, usage]
      end
    end

    def provider_output_schema(output_schema)
      return output_schema unless output_schema.respond_to?(:native_fallback?)
      return output_schema.schema unless @provider.respond_to?(:native_output_schema)

      @provider.native_output_schema(output_schema.schema)
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
        calls.each do |call|
          answer(call, ToolResult.new(content: ToolExecutor::INTERRUPTED, error: true), &emit)
        end
        return [[], false]
      end

      prepared, batch = prepare_tool_batch(calls, signal, &emit)
      return interrupt_tool_turn(prepared, signal, &emit) unless batch

      complete_tool_batch(calls, prepared, batch, signal, provider: assistant.provider, &emit)
    end

    def complete_tool_batch(source_calls, prepared, batch, signal, provider:, &emit)
      batch = protect_gemini_result_order(prepared, batch) if provider == :gemini
      invalid, blocked, parked, free, rejected = batch
      executed = execute(free, signal, &emit)
      if signal&.aborted?
        uncommitted = [*invalid, *blocked, *rejected].map(&:first) + parked
        results = [*executed, *interrupted_results(uncommitted)]
        answer_results(prepared, results, executed:, signal:, &emit)
        return [[], executed_ends_turn?(executed)]
      end

      answer_results(prepared, [*invalid, *blocked, *rejected, *executed],
                     executed:, signal:, &emit)
      if signal&.aborted?
        answer_results(prepared, interrupted_results(parked),
                       executed: [], signal:, &emit)
        return [[], executed_ends_turn?(executed)]
      end

      sources = source_calls.to_h { |call| [call.id, call] }
      parked.each do |call|
        source = sources.fetch(call.id)
        data = { "call" => call.to_h }
        data["prepared_from"] = "assistant" unless call == source
        @session.append("approval_request", data)
        emit&.call(Event.new(type: :approval_needed, tool_call: call))
      end
      [parked, executed_ends_turn?(executed)]
    end

    def executed_ends_turn?(executed)
      executed.any? { |call, _result, _seconds| ends_turn?(call) }
    end

    # Before Gemini 3, same-name parallel calls may have no wire IDs and only
    # order pairs their responses. A later immediate result cannot pass an
    # earlier parked result without becoming ambiguous.
    def protect_gemini_result_order(prepared, batch)
      invalid, blocked, parked, free, rejected = batch
      positions = prepared.each_with_index.to_h { |call, index| [call.id, index] }
      immediate = [*invalid, *blocked, *rejected].map(&:first) + free
      unsafe, safe = parked.partition do |parked_call|
        parked_call.provider_call_id.nil? && immediate.any? do |call|
          call.provider_call_id.nil? && call.name == parked_call.name &&
            positions.fetch(call.id) > positions.fetch(parked_call.id)
        end
      end
      failures = unsafe.map do |call|
        content = "Gemini returned parallel same-name calls without IDs across an approval " \
                  "boundary. This tool did not run; retry those calls separately."
        [call, ToolResult.new(content:, error: true), nil]
      end
      [invalid, blocked, safe, free, [*rejected, *failures]]
    end

    # Returns the calls that actually executed (denied ones only answer).
    def settle(open, signal, &)
      approved, denied = open.partition { |approval| approval[:decision]["approved"] }
      approved_calls = approved.map { |approval| approval[:call] }
      _prepared, valid, invalid = prepare_calls(
        approved_calls, normalize: false, signal:
      )
      return interrupt_settlement(open, approved_calls, denied, signal, &) if signal&.aborted?

      cleared, blocked = screen(valid, signal, &)
      return interrupt_settlement(open, approved_calls, denied, signal, &) if signal&.aborted?

      executed = execute(cleared, signal, &)
      denials = denial_results(denied)
      results = if signal&.aborted?
                  uncommitted = [*invalid, *blocked].map(&:first)
                  [*executed, *interrupted_results(uncommitted), *denials]
                else
                  [*invalid, *blocked, *executed, *denials]
                end
      answer_results(open.map { |approval| approval[:call] },
                     results, executed:, signal:, &)
      executed.map(&:first)
    end

    def interrupt_settlement(open, approved, denied, signal, &)
      results = [*interrupted_results(approved), *denial_results(denied)]
      answer_results(open.map { |approval| approval[:call] }, results,
                     executed: [], signal:, &)
      []
    end

    def denial_results(denied)
      denied.map do |approval|
        note = approval[:decision]["note"]
        text = "The user denied this tool call#{note ? ": #{note}" : "."}"
        [approval[:call], text, nil]
      end
    end

    # Provider output is untrusted until the call has resolved to a current
    # tool, passed its one allowed normalization, and satisfied both core and
    # host schema checks. Rejections stay paired in band, while valid siblings
    # continue through policy and execution.
    def prepare_calls(calls, normalize:, signal: nil)
      calls.each_with_object([[], [], []]) do |call, (ordered, valid, rejected)|
        if signal&.aborted?
          ordered << call
          next
        end

        prepared, result = prepare_call(call, normalize:, signal:)
        ordered << prepared
        if result
          rejected << [prepared, result, nil]
        else
          valid << prepared
        end
      end
    end

    def prepare_tool_batch(calls, signal, &)
      prepared, valid, invalid = prepare_calls(calls, normalize: true, signal:)
      return [prepared, nil] if signal&.aborted?

      screened, blocked = screen(valid, signal, &)
      return [prepared, nil] if signal&.aborted?

      parked, free, rejected = partition_approval(screened, signal)
      return [prepared, nil] if signal&.aborted?

      [prepared, [invalid, blocked, parked, free, rejected]]
    end

    def prepare_call(call, normalize:, signal: nil)
      call = call.with unless call.arguments_owned?
      tool = @tools_by_name[call.name]
      return [call, unavailable_tool(call.name)] unless tool

      if call.arguments_error
        violation = if call.arguments_error == "invalid_json"
                      "arguments were not valid JSON"
                    else
                      "arguments were not valid bounded JSON"
                    end
        return [call, argument_failure(call.name, violation)]
      end
      unless call.arguments.is_a?(Hash)
        return [call, argument_failure(call.name, "arguments must be a JSON object")]
      end

      prepared, failure = normalize ? normalize_call(tool, call) : [call, nil]
      return [prepared, nil] if signal&.aborted?
      return [prepared, failure] if failure

      [prepared, validate_call(tool, prepared)]
    end

    # Tool-result correlation is provider-owned opaque state. If any ID is
    # unusable, the whole assistant attempt is unpairable: discard it before
    # persistence and let the ordinary provider retry contract request a
    # clean turn. Inventing an ID would corrupt Anthropic tool_use_id and
    # OpenAI Responses call_id replay.
    def enforce_tool_call_envelope(message, held)
      unless message.is_a?(Message) && message.assistant?
        return reject_provider_message(message, "provider turns must be assistant messages")
      end

      violation = tool_call_envelope_violation(message.tool_calls) ||
                  provider_tool_call_violation(message)
      incomplete = message.tool_calls.any? { |call| call.arguments_error == "incomplete" }
      return [message, held] unless violation || incomplete

      if [StopReason::ERROR, StopReason::ABORTED, StopReason::LENGTH,
          StopReason::BUDGET].include?(message.stop_reason)
        sanitized = Message.assistant(content: message.content.grep_v(ToolCall),
                                      model: message.model, provider: message.provider,
                                      usage: message.usage, stop_reason: message.stop_reason,
                                      error_message: message.error_message, error: message.error)
        terminal = Event.new(type: held&.type || :error, reason: sanitized.stop_reason,
                             message: sanitized,
                             error_message: held&.error_message || sanitized.error_message)
        return [sanitized, terminal]
      end

      text = "The provider returned malformed tool-call metadata. No tools ran."
      detail = violation || "tool-call arguments were incomplete"
      failure = ProviderError.new("#{text} #{detail}.")
      rejected = Message.assistant(content: text, model: message.model,
                                   provider: message.provider, usage: message.usage,
                                   stop_reason: StopReason::ERROR,
                                   error_message: failure.message,
                                   error: ErrorData.for(failure))
      terminal = Event.new(type: :error, reason: StopReason::ERROR, message: rejected,
                           error_message: failure.message)
      [rejected, terminal]
    end

    def reject_provider_message(message, reason)
      text = "The provider returned an invalid message. No tools ran."
      failure = ProviderError.new("#{text} #{reason}.")
      usage = message.usage if message.is_a?(Message)
      rejected = Message.assistant(content: text, usage:, stop_reason: StopReason::ERROR,
                                   error_message: failure.message,
                                   error: ErrorData.for(failure))
      terminal = Event.new(type: :error, reason: StopReason::ERROR, message: rejected,
                           error_message: failure.message)
      [rejected, terminal]
    end

    # Gemini cryptographically binds a function call to its continuation.
    # Replacing malformed signed arguments with {} makes that continuation
    # fail at the provider, so the only replay-safe boundary is the complete
    # attempt: retry it without persisting any part of the bad turn.
    def provider_tool_call_violation(message)
      return unless message.provider == :gemini
      return unless message.tool_calls.any? do |call|
        call.arguments_error || !call.arguments.is_a?(Hash)
      end

      "Gemini function-call arguments must be a valid JSON object"
    end

    def tool_call_envelope_violation(calls)
      seen = {}
      seen_provider_ids = {}
      calls.each do |call|
        problem = call_id_problem(call.id)
        return problem if problem

        return "tool call IDs must be unique within a session" if @tool_call_ids.include?(call.id)

        problem = call_name_problem(call.name)
        return problem if problem

        problem = call_signature_problem(call.signature)
        return problem if problem

        if call.respond_to?(:provider_call_id)
          problem = provider_call_id_problem(call.provider_call_id)
          return problem if problem
          if call.provider_call_id && seen_provider_ids.key?(call.provider_call_id)
            return "provider tool call IDs must be unique within an assistant turn"
          end
        end

        return "tool call IDs must be unique within an assistant turn" if seen.key?(call.id)

        seen[call.id] = true
        seen_provider_ids[call.provider_call_id] = true if call.provider_call_id
      end
      nil
    end

    def refresh_tool_control
      state = @session.tool_control_state
      @tool_call_ids = state.fetch(:tool_call_ids)
      state.fetch(:approvals)
    end

    def reserve_tool_call_ids(calls)
      calls.each { |call| @tool_call_ids << call.id }
    end

    def call_name_problem(name)
      return "a tool name was missing" if name.nil?
      return "tool names must be strings" unless name.is_a?(String)
      unless name.encoding == Encoding::UTF_8 && name.valid_encoding?
        return "tool names must be valid UTF-8"
      end
      return "tool names must not be blank" if name.match?(/\A[[:space:]]*\z/)

      nil
    end

    def call_id_problem(id)
      return "a tool call ID was missing" if id.nil?
      return "tool call IDs must be strings" unless id.is_a?(String)
      unless id.encoding == Encoding::UTF_8 && id.valid_encoding?
        return "tool call IDs must be valid UTF-8"
      end
      return "tool call IDs must not be blank" if id.match?(/\A[[:space:]]*\z/)

      nil
    end

    def provider_call_id_problem(id)
      return nil if id.nil?
      return "provider tool call IDs must be strings" unless id.is_a?(String)
      unless id.encoding == Encoding::UTF_8 && id.valid_encoding?
        return "provider tool call IDs must be valid UTF-8"
      end
      return "provider tool call IDs must not be blank" if id.match?(/\A[[:space:]]*\z/)

      nil
    end

    def call_signature_problem(signature)
      return nil if signature.nil?
      return "tool call signatures must be strings" unless signature.is_a?(String)
      unless signature.encoding == Encoding::UTF_8 && signature.valid_encoding?
        return "tool call signatures must be valid UTF-8"
      end
      return "tool call signatures must not be blank" if signature.match?(/\A[[:space:]]*\z/)

      nil
    end

    def normalize_call(tool, call)
      return [call, nil] unless tool.respond_to?(:normalize_arguments)

      normalized = tool.normalize_arguments(call.arguments)
      prepared = normalized.equal?(call.arguments) ? call : call.with(arguments: normalized)
      if prepared.arguments_error || !prepared.arguments.is_a?(Hash)
        return [prepared, preparation_failure(call.name, "normalizer", TypeError)]
      end

      [prepared, nil]
    rescue StandardError => e
      [call, preparation_failure(call.name, "normalizer", e.class)]
    end

    def validate_call(tool, call)
      validator = @external_tool_validators[call.name]
      errors = if tool.is_a?(Tool)
                 TOOL_ARGUMENT_VALIDATOR.bind_call(tool, call.arguments, owned: true)
               else
                 validator&.violations(call.arguments, owned: true) || []
               end
      if errors.empty? && !tool.is_a?(Tool) && tool.respond_to?(:prepared_argument_violations)
        errors = tool.prepared_argument_violations(call.arguments)
      end
      errors.empty? ? nil : argument_failure(call.name, *errors)
    rescue StandardError => e
      preparation_failure(call.name, "validator", e.class)
    end

    def argument_failure(name, *violations)
      header = "Invalid arguments for tool #{tool_label(name)}:\n"
      footer = "\nThe tool did not run. Correct the arguments and try again."
      available = MAX_ARGUMENT_ERROR_BYTES - header.bytesize - footer.bytesize
      shown = violations.first(MAX_ARGUMENT_VIOLATIONS)
      shown[-1] = "additional violations were omitted" if violations.length > shown.length
      lines = shown.map do |violation|
        "- #{safe_violation(violation)}"
      end
      body = utf8_prefix(lines.join("\n"), available)
      ToolResult.new(content: "#{header}#{body}#{footer}", error: true)
    end

    def unavailable_tool(name)
      content = "Unknown tool #{tool_label(name)}. The tool did not run; choose an available tool."
      ToolResult.new(content: utf8_prefix(content, MAX_ARGUMENT_ERROR_BYTES), error: true)
    end

    def preparation_failure(name, phase, error_class)
      klass = safe_violation(error_class.name || "Exception")
      content = "Tool #{tool_label(name)} could not prepare arguments: its argument #{phase} " \
                "failed (#{utf8_prefix(klass, 120)}). The tool did not run. This is a host " \
                "configuration failure; do not retry the same call unchanged."
      ToolResult.new(content: utf8_prefix(content, MAX_ARGUMENT_ERROR_BYTES), error: true)
    end

    def compile_tool_contracts
      validators = {}
      specs = @tools.map do |tool|
        raw = tool.spec
        unless raw.is_a?(Hash)
          raise ConfigurationError, "tool #{tool.name.inspect} spec must be a Hash"
        end

        spec = raw.transform_keys(&:to_sym)
        schema = spec.fetch(:input_schema) do
          raise ConfigurationError, "tool #{tool.name.inspect} spec needs input_schema"
        end
        if tool.is_a?(Tool)
          schema = tool.input_schema
        else
          complete = tool.respond_to?(:prepared_argument_violations)
          plan = Schema.tool_validator(schema, complete:)
          validators[tool.name] = plan
          schema = plan.schema
        end
        spec.merge(input_schema: schema).freeze
      end
      [specs.freeze, validators.freeze]
    end

    def tool_label(name)
      safe = safe_violation(name)
      JSON.generate(utf8_prefix(safe, 120))
    end

    def safe_violation(violation)
      raw = violation.to_s
      prefix = raw.byteslice(0, MAX_VIOLATION_SOURCE_BYTES).dup.force_encoding(raw.encoding)
      prefix.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
            .gsub(/[[:space:]]+/, " ").strip
    end

    def utf8_prefix(text, bytes)
      return text if text.bytesize <= bytes
      return "" if bytes <= 3

      prefix = text.byteslice(0, bytes - 3).dup.force_encoding(Encoding::UTF_8)
      prefix = prefix.byteslice(0, prefix.bytesize - 1) until prefix.valid_encoding?
      "#{prefix}..."
    end

    # Runs calls without persisting them; the caller commits and rewrites
    # settled results in the model's original call order.
    def execute(calls, signal, &emit)
      return [] if calls.empty?

      ToolExecutor.call_with_outcomes(calls, @tools_by_name, signal: signal,
                                                             max_concurrency: @max_concurrency,
                                                             session: @session, emit: emit,
                                                             app: @context,
                                                             prepared_arguments: true)
    end

    def interrupt_tool_turn(calls, signal, &)
      answer_results(calls, interrupted_results(calls), executed: [], signal:, &)
      [[], false]
    end

    def interrupted_results(calls)
      calls.map do |call|
        result = ToolResult.new(content: ToolExecutor::INTERRUPTED, error: true)
        [call, result, nil]
      end
    end

    # A blocked call answers in band, so the model reads the reason and
    # reacts; a hook that raises blocks conservatively rather than letting
    # an unpoliced call through.
    def screen(calls, signal, &emit)
      return [calls, []] unless @before_tool

      context = hook_context(signal, emit)
      calls.each_with_object([[], []]) do |call, (cleared, blocked)|
        if signal&.aborted?
          cleared << call
          next
        end

        reason = begin
          @before_tool.call(call, context)
        rescue EventDelivery::Failure => e
          raise EventDelivery.unwrap(e, context.emit)
        rescue StandardError => e
          "the before_tool hook failed: #{e.class}: #{e.message}"
        end
        if reason.is_a?(String)
          result = ToolResult.new(content: "Blocked: #{reason}", error: true)
          blocked << [call, result, nil]
        else
          cleared << call
        end
      end
    end

    def rewrite(call, result, context)
      rewritten = @after_tool.call(call, result, context) || result
      return rewritten unless result.is_a?(ToolResult) && result.error?

      if rewritten.is_a?(ToolResult)
        rewritten.with(error: true)
      else
        ToolResult.new(content: rewritten, error: true)
      end
    rescue EventDelivery::Failure => e
      raise EventDelivery.unwrap(e, context.emit)
    rescue StandardError => e
      ToolResult.new(
        content: "Error in after_tool hook: #{e.class}: #{e.message}. The tool already returned; " \
                 "verify its effects before retrying.",
        error: true
      )
    end

    def hook_context(signal, emit)
      ToolContext.new(session: @session, signal: signal, emit: EventDelivery.wrap(emit),
                      app: @context)
    end

    # The tool message carries both channels; the :tool_result event exposes
    # it whole so hosts read event.message.ui for their side of the result.
    def answer(call, result, duration: nil, &emit)
      content, ui, tool_error = if result.is_a?(ToolResult)
                                  [result.content, result.ui, result.error?]
                                else
                                  [result, nil, false]
                                end
      message = @session.append_message(Message.tool(content: content, tool_call_id: call.id,
                                                     tool_name: call.name, ui: ui,
                                                     tool_error: tool_error))
      text = content.is_a?(String) ? content : "[content]"
      emit&.call(Event.new(type: :tool_result, tool_call: call, content: text,
                           message: message, duration: duration, tool_error: tool_error))
    end

    def answer_results(calls, results, executed:, signal:, &emit)
      executed_results = if @after_tool
                           {}.compare_by_identity.tap do |index|
                             executed.each { |result| index[result] = true if result[3] }
                           end
                         end
      by_call = {}.compare_by_identity
      results.each { |result| (by_call[result[0]] ||= []) << result }
      context = hook_context(signal, emit) if @after_tool
      calls.each do |call|
        queued = by_call[call]
        next unless queued && (entry = queued.shift)

        _call, result, seconds = entry
        result = rewrite(call, result, context) if executed_results&.key?(entry)
        answer(call, result, duration: seconds, &emit)
      end
    end

    def gated?(call)
      tool = @tools_by_name[call.name]
      tool ? tool.needs_approval?(call.arguments) : false
    end

    def partition_approval(calls, signal = nil)
      calls.each_with_object([[], [], []]) do |call, (parked, free, rejected)|
        if signal&.aborted?
          free << call
          next
        end

        (gated?(call) ? parked : free) << call
      rescue StandardError => e
        content = "Error evaluating approval policy for tool #{call.name.inspect}: " \
                  "#{e.class}: #{e.message}. The tool did not run."
        rejected << [call, ToolResult.new(content:, error: true), nil]
      end
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
