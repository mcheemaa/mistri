# frozen_string_literal: true

require_relative "lib/mistri/version"

Gem::Specification.new do |spec|
  spec.name = "mistri"
  spec.version = Mistri::VERSION
  spec.authors = ["Muhammad Ahmed Cheema"]
  spec.summary = "The agent harness for Ruby applications."
  spec.description = "Mistri (مستری) is the fixer: an agent harness that lives inside your " \
                     "app. Durable sessions in your own store, streaming, tools, " \
                     "fire-and-forget human approval, steering, compaction, structured " \
                     "output, skills, and sub-agents, across Anthropic, OpenAI, and " \
                     "Gemini, with zero runtime dependencies."
  spec.homepage = "https://mistri.sh"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = "https://github.com/mcheemaa/mistri"
  spec.metadata["changelog_uri"] = "https://github.com/mcheemaa/mistri/blob/main/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["documentation_uri"] =
    "https://github.com/mcheemaa/mistri/blob/v#{spec.version}/docs/README.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/mcheemaa/mistri/issues"

  # The .tt generator templates must ship, or rails g mistri:install breaks.
  public_files = Dir["lib/**/*.{rb,tt}", "docs/**/*.md", "assets/**/*", "examples/*.rb"]
                 .select { |path| File.file?(path) }
  root_files = %w[CHANGELOG.md CONTRIBUTING.md LICENSE NOTICE README.md SECURITY.md
                  UPGRADING.md mistri.gemspec]
  spec.files = (public_files + root_files).sort
  spec.require_paths = ["lib"]
end
