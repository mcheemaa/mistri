# frozen_string_literal: true

# The models the integration scenarios run on. The Rakefile reads this too, to
# start one process for each model.
module Integration
  DEFAULT_MODELS = "claude-haiku-5-5,gpt-6.1-terra,gemini-3.8-flash"

  def self.models
    ENV.fetch("MISTRI_INTEGRATION_MODELS", DEFAULT_MODELS).split(",").map(&:strip)
  end
end
