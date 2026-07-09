# frozen_string_literal: true

module Mistri
  # The model catalog: capability data for known models, with graceful
  # passthrough for unknown ones. An id missing here still works everywhere;
  # the catalog only improves defaults (output ceilings, provider inference),
  # so a brand-new model is usable the day it ships.
  module Models
    # thinking is how the model accepts a reasoning request: :adaptive (the
    # model decides), :budget (a token budget), or :effort. It is what keeps
    # a provider from sending an unsupported thinking shape that 400s.
    #
    # rates is the published API price in USD per million tokens; assemblers
    # price each turn's usage from it. cache_write is the 5-minute write
    # rate; the 1-hour slice bills at 2x input, which Usage#with_cost applies
    # on its own. An uncatalogued model reports zero cost, so a cost budget
    # never stops it. Long-context premium tiers (Gemini Pro and GPT past
    # 200k input) are not modeled; those turns under-count.
    Model = Data.define(:id, :provider, :max_output, :context_window, :thinking, :rates) do
      def initialize(id:, provider:, max_output:, context_window:, thinking:, rates: nil)
        super(id:, provider:, max_output:, context_window:, thinking:, rates: rates&.freeze)
      end
    end

    CATALOG = [
      ["claude-fable-5", :anthropic, 128_000, 200_000, :adaptive,
       { input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5 }],
      ["claude-opus-4-8", :anthropic, 128_000, 200_000, :adaptive,
       { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 }],
      ["claude-opus-4-7", :anthropic, 128_000, 200_000, :adaptive,
       { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 }],
      ["claude-opus-4-6", :anthropic, 128_000, 200_000, :adaptive,
       { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 }],
      # Introductory pricing through 2026-08-31; 3.0/15.0 (0.3/3.75) after.
      ["claude-sonnet-5", :anthropic, 128_000, 200_000, :adaptive,
       { input: 2.0, output: 10.0, cache_read: 0.2, cache_write: 2.5 }],
      ["claude-sonnet-4-6", :anthropic, 128_000, 200_000, :adaptive,
       { input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75 }],
      ["claude-haiku-4-5", :anthropic, 64_000, 200_000, :budget,
       { input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25 }],
      ["gpt-5.5", :openai, 128_000, 400_000, :effort,
       { input: 5.0, output: 30.0, cache_read: 0.5 }],
      ["gpt-5.4", :openai, 128_000, 400_000, :effort,
       { input: 2.5, output: 15.0, cache_read: 0.25 }],
      ["gpt-5-nano", :openai, 128_000, 400_000, :effort,
       { input: 0.05, output: 0.4, cache_read: 0.005 }],
      ["gemini-3.5-flash", :gemini, 65_536, 1_048_576, :level,
       { input: 1.5, output: 9.0, cache_read: 0.15 }],
      ["gemini-3.1-pro-preview", :gemini, 65_536, 1_048_576, :level,
       { input: 2.0, output: 12.0, cache_read: 0.2 }],
      ["gemini-2.5-pro", :gemini, 65_536, 1_048_576, :budget,
       { input: 1.25, output: 10.0, cache_read: 0.125 }],
      ["gemini-2.5-flash", :gemini, 65_536, 1_048_576, :budget,
       { input: 0.3, output: 2.5, cache_read: 0.03 }]
    ].to_h { |row| [row.first, Model.new(*row)] }.freeze

    # Dated aliases resolve to their base entry: claude-opus-4-8-20260115 and
    # gpt-5.4-2025-04-14 both match their base ids.
    def self.find(id)
      CATALOG[id] || CATALOG[id.to_s.sub(/-\d{8}\z/, "").sub(/-\d{4}-\d{2}-\d{2}\z/, "")]
    end

    def self.max_output(id) = find(id)&.max_output

    def self.thinking(id) = find(id)&.thinking

    def self.rates(id) = find(id)&.rates
  end
end
