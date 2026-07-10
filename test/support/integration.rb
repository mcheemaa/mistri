# frozen_string_literal: true

require_relative "../test_helper"

# The live integration harness: every scenario runs the full loop against
# real provider APIs, once per model in the matrix. Every assertion checks
# that a GENERATED codename flowed through the machinery: a coined ghostly
# word like Spectramoor exists in no training data, so its presence in an
# answer proves the tool result, summary, or child transcript carried it.
#
#   bundle exec rake integration
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

  # A single coined specter of a word no model has ever seen; only our
  # machinery can deliver it into an answer.
  def codename
    "#{STARTS.sample}#{MIDDLES.sample}#{ENDS.sample}"
  end

  def saw?(text, code)
    text.to_s.downcase.include?(code.downcase)
  end

  # Defines one live test per model in the matrix; each skips itself when
  # its provider's key is absent.
  def scenario(klass, name, &body)
    models.each do |model|
      klass.define_method("test_#{name}_on_#{model.gsub(/[^a-z0-9]/i, "_")}") do
        key = Mistri::API_KEY_ENV.fetch(Mistri.provider_name(model))
        skip "#{key} not set" if ENV[key].to_s.empty?
        instance_exec(model, &body)
      end
    end
  end
end
