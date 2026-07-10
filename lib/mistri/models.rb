# frozen_string_literal: true

require "json"

module Mistri
  # The model catalog: capability data for known models, with graceful
  # passthrough for unknown ones. An id missing here still works everywhere;
  # the catalog supplies capability defaults and paid direct-API pricing, so a
  # brand-new model remains usable unless the host requests a cost ceiling.
  module Models
    EMPTY_PRICING = [].freeze

    # One request's standard rates and optional prompt-size tier.
    RateCard = Data.define(:rates, :above, :higher) do
      def initialize(rates:, above: nil, higher: nil)
        if above.nil? != higher.nil?
          raise ArgumentError, "a pricing threshold needs both above and higher"
        end

        super(rates: rates.freeze, above:, higher: higher&.freeze)
      end

      def rates_for(usage)
        usage && above && usage.prompt_tokens > above ? higher : rates
      end
    end

    # A rate card that becomes active at one absolute instant.
    Schedule = Data.define(:effective_at, :card)

    # thinking is how the model accepts a reasoning request: :adaptive (the
    # model decides), :budget (a token budget), or :effort. It is what keeps
    # a provider from sending an unsupported thinking shape that 400s.
    #
    # context_window is the provider's published context or input limit.
    # Anthropic and OpenAI share it with the next output; Gemini publishes a
    # separate inputTokenLimit and outputTokenLimit.
    #
    # Pricing is selected per request from its prompt size. Rates are paid
    # standard direct-API list prices. cache_write is the 5-minute write rate;
    # Usage applies the 1-hour rate separately.
    Model = Data.define(:id, :provider, :max_output, :context_window, :thinking) do
      def initialize(id:, provider:, max_output:, context_window:, thinking:, pricing: [])
        @pricing = pricing.sort_by(&:effective_at).freeze
        super(id:, provider:, max_output:, context_window:, thinking:)
      end

      def rates(usage: nil, at: Time.now)
        pricing.reverse_each.find { |entry| entry.effective_at <= at }&.card&.rates_for(usage)
      end

      def priced? = !pricing.empty?

      def with(**changes)
        updated_pricing = changes.delete(:pricing) { pricing }
        self.class.new(**to_h, **changes, pricing: updated_pricing)
      end

      def ==(other) = super && pricing == other.send(:pricing)

      alias_method :eql?, :==

      def hash = [super, pricing].hash

      def _dump(_level)
        serialized = pricing.map do |entry|
          { effective_at: entry.effective_at.to_i, rates: entry.card.rates,
            above: entry.card.above, higher: entry.card.higher }
        end
        JSON.generate(to_h.merge(pricing: serialized))
      end

      def self._load(payload)
        attributes = JSON.parse(payload, symbolize_names: true)
        serialized = attributes.delete(:pricing)
        pricing = serialized.map do |entry|
          card = RateCard.new(rates: entry[:rates], above: entry[:above],
                              higher: entry[:higher])
          Schedule.new(effective_at: Time.at(entry[:effective_at]).utc, card:)
        end
        attributes[:provider] = attributes[:provider].to_sym
        attributes[:thinking] = attributes[:thinking].to_sym
        new(**attributes, pricing:)
      end

      private

      def pricing = @pricing || EMPTY_PRICING
    end

    EPOCH = Time.at(0).utc.freeze

    def self.price(rates = nil, from: EPOCH, above: nil, higher: nil, **flat_rates)
      rates ||= flat_rates
      Schedule.new(effective_at: from,
                   card: RateCard.new(rates:, above:, higher:))
    end
    private_class_method :price

    CATALOG = [
      ["claude-fable-5", :anthropic, 128_000, 1_000_000, :adaptive,
       [price(input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5)]],
      ["claude-opus-4-8", :anthropic, 128_000, 1_000_000, :adaptive,
       [price(input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25)]],
      ["claude-opus-4-7", :anthropic, 128_000, 1_000_000, :adaptive,
       [price(input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25)]],
      ["claude-opus-4-6", :anthropic, 128_000, 1_000_000, :adaptive,
       [price(input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25)]],
      ["claude-sonnet-5", :anthropic, 128_000, 1_000_000, :adaptive,
       [price(input: 2.0, output: 10.0, cache_read: 0.2, cache_write: 2.5),
        price({ input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75 },
              from: Time.utc(2026, 9, 1))]],
      ["claude-sonnet-4-6", :anthropic, 128_000, 1_000_000, :adaptive,
       [price(input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75)]],
      ["claude-haiku-4-5", :anthropic, 64_000, 200_000, :budget,
       [price(input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25)]],
      ["gpt-5.5", :openai, 128_000, 1_050_000, :effort,
       [price({ input: 5.0, output: 30.0, cache_read: 0.5 },
              above: 272_000, higher: { input: 10.0, output: 45.0, cache_read: 1.0 })]],
      ["gpt-5.4", :openai, 128_000, 1_050_000, :effort,
       [price({ input: 2.5, output: 15.0, cache_read: 0.25 },
              above: 272_000, higher: { input: 5.0, output: 22.5, cache_read: 0.5 })]],
      ["gpt-5-nano", :openai, 128_000, 400_000, :effort,
       [price(input: 0.05, output: 0.4, cache_read: 0.005)]],
      ["gemini-3.5-flash", :gemini, 65_536, 1_048_576, :level,
       [price(input: 1.5, output: 9.0, cache_read: 0.15)]],
      ["gemini-3.1-pro-preview", :gemini, 65_536, 1_048_576, :level,
       [price({ input: 2.0, output: 12.0, cache_read: 0.2 },
              above: 200_000, higher: { input: 4.0, output: 18.0, cache_read: 0.4 })]],
      ["gemini-2.5-pro", :gemini, 65_536, 1_048_576, :budget,
       [price({ input: 1.25, output: 10.0, cache_read: 0.125 },
              above: 200_000, higher: { input: 2.5, output: 15.0, cache_read: 0.25 })]],
      ["gemini-2.5-flash", :gemini, 65_536, 1_048_576, :budget,
       [price(input: 0.3, output: 2.5, cache_read: 0.03)]]
    ].to_h do |row|
      id, provider, max_output, context_window, thinking, pricing = row
      [id, Model.new(id:, provider:, max_output:, context_window:, thinking:, pricing:)]
    end.freeze

    # Dated aliases resolve to their base entry: claude-opus-4-8-20260115 and
    # gpt-5.4-2025-04-14 both match their base ids.
    def self.find(id)
      CATALOG[id] || CATALOG[id.to_s.sub(/-\d{8}\z/, "").sub(/-\d{4}-\d{2}-\d{2}\z/, "")]
    end

    def self.max_output(id) = find(id)&.max_output

    # Output capacity that occupies the published context limit. Gemini's
    # output limit is independent, so its compaction headroom is input-only.
    def self.shared_output(id)
      model = find(id)
      model&.max_output unless model&.provider == :gemini
    end

    def self.thinking(id) = find(id)&.thinking

    def self.rates(id, usage: nil, at: Time.now) = find(id)&.rates(usage:, at:)

    def self.priced?(id) = find(id)&.priced? || false
  end
end
