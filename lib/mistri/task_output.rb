# frozen_string_literal: true

require "json"

module Mistri
  # The text side of task mode: how a schema is asked for, how the answer
  # parses, and how a violation is sent back for a fix. Pure functions over
  # strings and schemas; Agent#task owns the loop that drives them.
  module TaskOutput
    # Distinguishable from a parsed nil: JSON "null" is a valid value.
    PARSE_FAILED = Object.new.freeze

    module_function

    def prompt(input, schema)
      "#{input}\n\nAnswer with ONLY a JSON value matching this schema:\n" \
        "#{JSON.generate(Schema.strict(schema))}"
    end

    def parse(text)
      body = text.to_s.strip
      body = body[/\A```(?:json)?\s*(.*?)```\z/m, 1] || body
      JSON.parse(body)
    rescue JSON::ParserError
      PARSE_FAILED
    end

    def errors(value, schema)
      return ["the answer is not valid JSON"] if value.equal?(PARSE_FAILED)

      Schema.violations(value, schema)
    end

    def fix_prompt(errors)
      lines = errors.map { |error| "- #{error}" }.join("\n")
      "Your answer did not satisfy the required output schema. Problems:\n" \
        "#{lines}\nReply with ONLY the corrected JSON."
    end
  end
end
