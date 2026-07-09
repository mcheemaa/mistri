# frozen_string_literal: true

require "json"

module Mistri
  # Token accounting for an assistant turn, and the dollar cost of those tokens.
  #
  # `input` counts only prompt tokens billed at the full rate: cache reads and
  # writes are separate fields, so a cached token is never double-billed.
  # `reasoning` is the thinking slice of `output`. `cache_write_1h` is the slice
  # of `cache_write` held for an hour, which bills at twice the input rate.
  class Usage < Data.define(:input, :output, :cache_read, :cache_write,
                            :cache_write_1h, :reasoning, :cost)
    # Dollar amounts plus whether every contributing token had known pricing.
    # Known stays outside the released Data shape so pattern matching and
    # positional construction remain compatible.
    Cost = Data.define(:input, :output, :cache_read, :cache_write, :total) do
      def initialize(input:, output:, cache_read:, cache_write:, total:, known: true)
        @known = known == true
        super(input:, output:, cache_read:, cache_write:, total:)
      end

      def self.zero
        new(input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0,
            total: 0.0, known: true)
      end

      def self.unknown
        new(input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0,
            total: 0.0, known: false)
      end

      def known? = defined?(@known) ? @known : true

      def with(**changes)
        self.class.new(**to_h, **changes)
      end

      def +(other)
        self.class.new(input: input + other.input, output: output + other.output,
                       cache_read: cache_read + other.cache_read,
                       cache_write: cache_write + other.cache_write,
                       total: total + other.total, known: known? && other.known?)
      end

      def ==(other) = super && known? == other.known?

      alias_method :eql?, :==

      def hash = [super, known?].hash

      def to_h = super.merge(known: known?)

      def _dump(_level) = JSON.generate(to_h)

      def self._load(payload) = new(**JSON.parse(payload, symbolize_names: true))
    end

    def initialize(input: 0, output: 0, cache_read: 0, cache_write: 0,
                   cache_write_1h: 0, reasoning: 0, cost: Cost.unknown)
      super
    end

    def self.zero = new(cost: Cost.zero)

    def self.from_h(hash)
      h = (hash || {}).transform_keys(&:to_s)
      c = (h["cost"] || {}).transform_keys(&:to_s)
      counts = { input: h.fetch("input", 0).to_i, output: h.fetch("output", 0).to_i,
                 cache_read: h.fetch("cache_read", 0).to_i,
                 cache_write: h.fetch("cache_write", 0).to_i,
                 cache_write_1h: h.fetch("cache_write_1h", 0).to_i,
                 reasoning: h.fetch("reasoning", 0).to_i }
      amounts = { input: c.fetch("input", 0).to_f, output: c.fetch("output", 0).to_f,
                  cache_read: c.fetch("cache_read", 0).to_f,
                  cache_write: c.fetch("cache_write", 0).to_f,
                  total: c.fetch("total", 0).to_f }
      known = c.fetch("known", false) == true
      known ||= !c.key?("known") && counts.values.all?(&:zero?) && amounts.values.all?(&:zero?)
      new(**counts, cost: Cost.new(**amounts, known:))
    end

    def prompt_tokens = input + cache_read + cache_write

    def total_tokens = input + output + cache_read + cache_write

    # A copy with cost computed from per-million-token rates. The 1h cache-write
    # slice bills at the :cache_write_1h rate when given, else at twice the
    # input rate, matching extended-retention pricing.
    def with_cost(rates)
      long = [cache_write_1h, cache_write].min
      short = cache_write - long
      computed = {
        input: rate(rates, :input) * input,
        output: rate(rates, :output) * output,
        cache_read: rate(rates, :cache_read) * cache_read,
        cache_write: (rate(rates, :cache_write) * short) + (long_write_rate(rates) * long)
      }
      with(cost: Cost.new(**computed,
                          total: computed.values.sum,
                          known: rates_cover?(rates, short, long)))
    end

    def +(other)
      self.class.new(input: input + other.input, output: output + other.output,
                     cache_read: cache_read + other.cache_read,
                     cache_write: cache_write + other.cache_write,
                     cache_write_1h: cache_write_1h + other.cache_write_1h,
                     reasoning: reasoning + other.reasoning,
                     cost: cost + other.cost)
    end

    def to_h = super.merge(cost: cost.to_h)

    private

    def rate(rates, key) = rates.fetch(key, 0).to_f / 1_000_000

    def long_write_rate(rates)
      rates.key?(:cache_write_1h) ? rate(rates, :cache_write_1h) : rate(rates, :input) * 2
    end

    def rates_cover?(rates, short, long)
      (input.zero? || rates.key?(:input)) &&
        (output.zero? || rates.key?(:output)) &&
        (cache_read.zero? || rates.key?(:cache_read)) &&
        (short.zero? || rates.key?(:cache_write)) &&
        (long.zero? || rates.key?(:cache_write_1h) || rates.key?(:input))
    end
  end
end
