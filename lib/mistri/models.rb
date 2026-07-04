# frozen_string_literal: true

module Mistri
  # The model catalog: capability data for known models, with graceful
  # passthrough for unknown ones. An id missing here still works everywhere;
  # the catalog only improves defaults (output ceilings, provider inference),
  # so a brand-new model is usable the day it ships.
  module Models
    Model = Data.define(:id, :provider, :max_output, :context_window)

    CATALOG = [
      ["claude-fable-5", :anthropic, 128_000, 200_000],
      ["claude-opus-4-8", :anthropic, 128_000, 200_000],
      ["claude-opus-4-7", :anthropic, 128_000, 200_000],
      ["claude-opus-4-6", :anthropic, 128_000, 200_000],
      ["claude-sonnet-5", :anthropic, 128_000, 200_000],
      ["claude-sonnet-4-6", :anthropic, 128_000, 200_000],
      ["claude-haiku-4-5", :anthropic, 64_000, 200_000],
      ["gpt-5.5", :openai, 128_000, 400_000],
      ["gpt-5.4", :openai, 128_000, 400_000],
      ["gpt-5-nano", :openai, 128_000, 400_000],
      ["gemini-3.5-flash", :gemini, 65_536, 1_048_576],
      ["gemini-3.1-pro-preview", :gemini, 65_536, 1_048_576],
      ["gemini-2.5-pro", :gemini, 65_536, 1_048_576],
      ["gemini-2.5-flash", :gemini, 65_536, 1_048_576]
    ].to_h do |id, provider, max_output, context_window|
      [id, Model.new(id:, provider:, max_output:, context_window:)]
    end.freeze

    # Dated aliases resolve to their base entry: claude-opus-4-8-20260115 and
    # gpt-5.4-2025-04-14 both match their base ids.
    def self.find(id)
      CATALOG[id] || CATALOG[id.to_s.sub(/-\d{8}\z/, "").sub(/-\d{4}-\d{2}-\d{2}\z/, "")]
    end

    def self.max_output(id) = find(id)&.max_output
  end
end
