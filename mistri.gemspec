require_relative "lib/mistri/version"

Gem::Specification.new do |spec|
  spec.name = "mistri"
  spec.version = Mistri::VERSION
  spec.authors = ["Muhammad Ahmed Cheema"]
  spec.summary = "Mistri: an agent harness for Ruby applications."
  spec.description = "Mistri (مستری) is the fixer: an agent harness for Ruby applications. " \
                     "First release coming soon."
  spec.homepage = "https://github.com/ghostwright/mistri"
  spec.license = "MIT"
  spec.metadata["source_code_uri"] = "https://github.com/ghostwright/mistri"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
