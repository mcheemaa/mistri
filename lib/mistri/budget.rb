# frozen_string_literal: true

module Mistri
  # Optional ceilings on a run: turns, tokens, dollars, wall-clock seconds.
  # Nothing is enforced unless the host sets it; an empty budget never stops a
  # run. The loop asks #exceeded? between turns, so a run always finishes the
  # turn it is in rather than tearing off mid-stream.
  class Budget
    def initialize(turns: nil, tokens: nil, cost_usd: nil, wall_clock: nil, clock: nil)
      @turns = turns
      @tokens = tokens
      @cost_usd = cost_usd
      @wall_clock = wall_clock
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @started = @clock.call
    end

    def none? = [@turns, @tokens, @cost_usd, @wall_clock].all?(&:nil?)

    # The reason the run should stop, or nil to continue.
    def exceeded(turns:, usage:)
      return :turns if @turns && turns >= @turns
      return :tokens if @tokens && usage.total_tokens >= @tokens
      return :cost if @cost_usd && usage.cost.total >= @cost_usd
      return :wall_clock if @wall_clock && (@clock.call - @started) >= @wall_clock

      nil
    end
  end
end
