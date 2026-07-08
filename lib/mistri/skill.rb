# frozen_string_literal: true

module Mistri
  # One expert playbook: a name the model selects by, a description that
  # earns the selection, and the full body it reads before acting. Build
  # them from anywhere: Skills.load reads a directory, and a host with
  # skills in a database constructs these directly.
  Skill = Data.define(:name, :description, :body) do
    def initialize(name:, description: "", body: "")
      raise ConfigurationError, "a skill needs a name" if name.to_s.empty?

      super(name: name.to_s, description: description.to_s, body: body.to_s)
    end
  end
end
