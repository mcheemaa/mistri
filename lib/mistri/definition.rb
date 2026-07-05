# frozen_string_literal: true

require "yaml"

module Mistri
  # An agent definition: a markdown file whose YAML frontmatter carries the
  # config and whose body is the prompt. Prompts stay editable prose in
  # files a reviewer can diff; code stays out of them.
  #
  #   ---
  #   role: Trip Planner
  #   model: claude-opus-4-8
  #   tools:
  #     - search_flights
  #     - book_hotel
  #   ---
  #   You plan trips end to end. Address the traveler as {first_name}.
  #
  #   definition = Mistri::Definition.load("app/agents/trip_planner.md")
  #   agent = Mistri.agent(definition.model,
  #                        system: definition.render(first_name: traveler.first_name),
  #                        tools: registry.build(definition.tools, traveler))
  #
  # The gem reads the file; what tool names mean, and what any extra
  # frontmatter keys mean, stays the host's vocabulary via #config.
  class Definition
    FRONTMATTER = /\A---\s*\n(?<yaml>.*?)\n---\s*\n(?<body>.*)\z/m

    attr_reader :name, :body, :config

    def self.load(path)
      match = FRONTMATTER.match(File.read(path))
      raise ConfigurationError, "#{path} has no frontmatter" unless match

      config = YAML.safe_load(match[:yaml]) || {}
      raise ConfigurationError, "#{path} frontmatter is not a mapping" unless config.is_a?(Hash)

      new(name: File.basename(path.to_s, ".md"), config: config, body: match[:body].strip)
    end

    def initialize(name:, config:, body:)
      @name = name.to_s
      @config = config.freeze
      @body = body
      freeze
    end

    def model = config["model"]

    def role = config["role"]

    # Tool declarations as a name => options map. A bare list means no
    # options; a map form carries per-tool options in the host's
    # vocabulary (gates, caching, whatever the host honors).
    def tools
      raw = config["tools"]
      entries = case raw
                when Hash then raw.transform_values { |options| options || {} }
                when Array then raw.to_h { |tool| [tool, {}] }
                else {}
                end
      entries.transform_keys(&:to_s)
    end

    def tool_names = tools.keys

    # The body with {placeholders} filled in. An unfilled placeholder
    # raises: a prompt silently addressing "{first_name}" is worse than an
    # error. A value of nil renders as empty, which lets optional context
    # collapse cleanly.
    def render(vars = {})
      vars = vars.transform_keys(&:to_s)
      body.gsub(/\{(\w+)\}/) do
        vars.fetch(Regexp.last_match(1)) do |key|
          raise ConfigurationError, "no value for {#{key}} in the #{name} definition"
        end
      end
    end
  end
end
