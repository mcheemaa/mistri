# frozen_string_literal: true

require "securerandom"
require_relative "../test_helper"

# The live integration harness runs the full loop against real provider APIs,
# once per model in the matrix. Scenarios pair generated values with structural
# assertions. Opaque markers prove exact data flow; pronounceable synthetic
# names keep entity prompts natural without relying on a real company or person.
#
#   bundle exec rake integration
#   MISTRI_INTEGRATION_STRICT=1 bundle exec rake integration
#   MISTRI_INTEGRATION_MODELS=claude-opus-4-8 bundle exec rake integration
#   bundle exec rake integration N=/compaction/
module Integration
  DEFAULT_MODELS = "claude-haiku-4-5-20251001,gpt-5.6-terra,gemini-2.5-flash"

  STARTS = %w[Spec Wraith Phan Umbra Shade Geist Vesper Haunt Grim Sable Mora Ecto].freeze
  MIDDLES = %w[a o e u ora ile ar in].freeze
  ENDS = %w[moor wyn vane gale mire veil whisp mist fell dusk holt shade].freeze

  module_function

  def models
    ENV.fetch("MISTRI_INTEGRATION_MODELS", DEFAULT_MODELS).split(",").map(&:strip)
  end

  # A pronounceable name for fictional entities supplied in the prompt.
  def codename
    "#{STARTS.sample}#{MIDDLES.sample}#{ENDS.sample}"
  end

  # A fresh opaque value only the scenario can place in the model's context.
  def marker
    "MISTRI_#{SecureRandom.hex(8)}"
  end

  def saw?(text, code)
    text.to_s.downcase.include?(code.downcase)
  end

  def carried?(text, value)
    text.to_s.include?(value.to_s)
  end

  def number?(text, value)
    text.to_s.match?(/(?<!\d)#{Regexp.escape(value.to_s)}(?!\d)/)
  end

  def strict?
    ENV["MISTRI_INTEGRATION_STRICT"] == "1"
  end

  def mcp_unreachable?(error)
    error.instance_of?(Mistri::ProviderError) && error.status.nil? &&
      error.message.match?(/\A(?:connection failed|request timed out):/)
  end

  # Defines one live test per model in the matrix. Local runs skip absent
  # keys; release verification fails instead.
  def scenario(klass, name, &body)
    models.each do |model|
      klass.define_method("test_#{name}_on_#{model.gsub(/[^a-z0-9]/i, "_")}") do
        key = Mistri::API_KEY_ENV.fetch(Mistri.provider_name(model))
        if ENV[key].to_s.empty?
          message = "#{key} not set"
          Integration.strict? ? flunk(message) : skip(message)
        end
        instance_exec(model, &body)
      end
    end
  end
end
