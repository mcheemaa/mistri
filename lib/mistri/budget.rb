# frozen_string_literal: true

module Mistri
  # Optional per-run ceilings: turns, tokens, dollars, wall-clock seconds.
  # Nothing is enforced unless the host sets it; an empty budget never stops a
  # run. Pure limits with no clock of its own, so one Budget shared across
  # agents or runs behaves identically for each: the loop measures and asks
  # between turns, and a run always finishes the turn it is in.
  class Budget
    def initialize(turns: nil, tokens: nil, cost_usd: nil, wall_clock: nil)
      @turns = turns
      @tokens = tokens
      @cost_usd = cost_usd
      @wall_clock = wall_clock
    end

    def none? = [@turns, @tokens, @cost_usd, @wall_clock].all?(&:nil?)

    def cost? = !@cost_usd.nil?

    def validate_provider!(provider)
      return unless cost?
      return if provider.respond_to?(:prices_usage?) && provider.prices_usage?

      raise ConfigurationError,
            "cost budget requires a catalogued model, list-priced origin, and deterministic " \
            "standard service tier for #{provider.model.inspect}"
    end

    def validate_usage!(usage)
      return unless cost?
      return if usage.cost.known?

      raise BudgetError.new(
        "cost budget cannot continue after a request returned unpriced usage; not retrying",
        usage:
      )
    end

    # The reason the run should stop, or nil to continue.
    def exceeded(turns:, usage:, elapsed: 0)
      return :turns if @turns && turns >= @turns
      return :tokens if @tokens && usage.total_tokens >= @tokens

      if @cost_usd
        validate_usage!(usage)
        return :cost if usage.cost.total >= @cost_usd
      end
      return :wall_clock if @wall_clock && elapsed >= @wall_clock

      nil
    end
  end
end
