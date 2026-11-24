# frozen_string_literal: true

module Mistri
  # Walks the calls of one turn in the order the model wrote them. Calls of
  # tools marked parallel that sit next to each other are one step and run
  # together; any other call is a step alone, after everything before it.
  #
  # A call that runs alone and does not take effect holds back the rest of
  # the turn, because a later call may rely on it. A call that waits for a
  # person holds back the rest as well: a read written after it would return
  # what was there before it. A call that needs approval waits with it, so a
  # person sees both, until a held or refused call that is not marked comes
  # between them: the later one may rely on that call.
  class CallOrder
    FAILED = "Not run: the %<name>s call before this one failed."
    WAITING = "Not run: the %<name>s call before this one waits for a person's approval. " \
              "Send this call again once it is decided."

    # executed holds the entries the steps returned. skipped holds
    # [call, result, nil] for a call that never started. parked holds the
    # calls that still wait.
    Outcome = Data.define(:executed, :skipped, :parked)

    def initialize(tools_by_name)
      @tools = tools_by_name
    end

    # refused entries were answered before execution, and one that is not
    # marked holds back the rest. denied ones were answered by a person's no
    # and hold back nothing. The block runs one step and returns its entries.
    def run(calls, refused: [], denied: [], parked: [], signal: nil, &run_step)
      @run_step = run_step
      @signal = signal
      @held = nil
      @closed = false
      @step = []
      @outcome = Outcome.new(executed: [], skipped: [], parked: [])
      kinds = kinds_of(refused, denied, parked)
      calls.each { |call| place(call, kinds[call]) }
      flush
      @outcome
    end

    # The calls that would wait for a person if every call that runs took
    # effect. A call that fails can only take calls out of them.
    def waiting(calls, refused: [], parked: [])
      run(calls, refused:, parked:) { |step| step.map { |call| [call] } }.parked
    end

    private

    def kinds_of(refused, denied, parked)
      kinds = {}.compare_by_identity
      refused.each { |entry| kinds[entry.first] = :refused }
      denied.each { |entry| kinds[entry.first] = :denied }
      parked.each { |call| kinds[call] = :parked }
      kinds
    end

    def place(call, kind)
      case kind
      when :denied then nil
      when :refused then fail_at(call) unless parallel?(call)
      when :parked then park(call)
      else free(call)
      end
    end

    def park(call)
      return skip(call) if failed? || @closed

      flush
      @held ||= [WAITING, call]
      @outcome.parked << call
    end

    def free(call)
      return hold_back(call) if @held
      return @step << call if parallel?(call)

      alone(call)
    end

    # A later call that needs approval may rely on a call that is not marked,
    # so none waits once one was held back.
    def hold_back(call)
      @closed ||= !parallel?(call)
      skip(call)
    end

    def alone(call)
      flush
      entry = execute([call]).first
      fail_at(call) if entry && failure?(entry[1])
    end

    def flush
      step = @step
      @step = []
      execute(step) unless step.empty?
    end

    # An abort leaves the calls that have not started to the caller, which
    # answers each as interrupted.
    def execute(step)
      if @signal&.aborted?
        step.each { |call| @outcome.skipped << [call, interrupted, nil] }
        return []
      end

      @run_step.call(step).tap { |entries| @outcome.executed.concat(entries) }
    end

    # The name is the model's own text when no tool has it, so it is bounded
    # as the agent bounds a name in its other messages.
    def skip(call)
      text, holder = @held
      name = holder.name.gsub(/[[:space:]]+/, " ")[0, 120]
      @outcome.skipped << [call, ToolResult.new(content: format(text, name:), error: true), nil]
    end

    def fail_at(call)
      @held = [FAILED, call] unless failed?
    end

    def failed? = @held&.first.equal?(FAILED)

    def failure?(result) = result.is_a?(ToolResult) && result.error?

    def interrupted = ToolResult.new(content: ToolExecutor::INTERRUPTED, error: true)

    def parallel?(call)
      tool = @tools[call.name]
      tool.respond_to?(:parallel?) && tool.parallel?
    end
  end
end
