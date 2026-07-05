# frozen_string_literal: true

require_relative "lib/mistri/version"

Gem::Specification.new do |spec|
  spec.name = "mistri"
  spec.version = Mistri::VERSION
  spec.authors = ["Muhammad Ahmed Cheema"]
  spec.summary = "The agent harness for Ruby applications."
  spec.description = "Mistri (مستری) is the fixer: an agent harness that lives inside your " \
                     "app. Durable sessions in your own database, streaming, tools, " \
                     "fire-and-forget human approval, steering, compaction, structured " \
                     "output, skills, and sub-agents, across Anthropic, OpenAI, and " \
                     "Gemini, with zero runtime dependencies."
  spec.homepage = "https://github.com/mcheemaa/mistri"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = "https://github.com/mcheemaa/mistri"
  spec.metadata["changelog_uri"] = "https://github.com/mcheemaa/mistri/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/mistri"
  spec.metadata["bug_tracker_uri"] = "https://github.com/mcheemaa/mistri/issues"

  # The .tt generator templates must ship, or rails g mistri:install breaks.
  spec.files = Dir["lib/**/*.{rb,tt}", "README.md", "LICENSE", "NOTICE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
end
