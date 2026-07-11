# frozen_string_literal: true

require "json"

module Mistri
  # The text side of task mode: how a schema is asked for, how the answer
  # parses, and how a violation is sent back for a fix. Pure functions over
  # strings and schemas; Agent#task owns the loop that drives them.
  module TaskOutput
    # Distinguishable from a parsed nil: JSON "null" is a valid value.
    PARSE_FAILED = Object.new.freeze
    OUTPUT_TOO_LARGE = Object.new.freeze
    OUTPUT_TOO_COMPLEX = Object.new.freeze

    module_function

    def prompt(input, schema)
      plan = plan_for(schema)
      "#{input}\n\nAnswer with ONLY a JSON value matching this schema:\n" \
        "#{JSON.generate(plan.schema)}"
    end

    def parse(text)
      body = text.to_s
      return OUTPUT_TOO_LARGE if body.bytesize > ToolArguments::MAX_BYTES

      body = body.strip
      body = body[/\A```(?:json)?\s*(.*?)```\z/m, 1] || body
      value, error = ToolArguments.parse_json(body)
      return OUTPUT_TOO_LARGE if error == "too_large"
      return OUTPUT_TOO_COMPLEX if %w[too_deep too_many_nodes number_too_large].include?(error)
      return PARSE_FAILED if error

      value
    end

    def errors(value, schema)
      return ["the answer exceeds the output byte limit"] if value.equal?(OUTPUT_TOO_LARGE)
      return ["the answer exceeds the output complexity limit"] if value.equal?(OUTPUT_TOO_COMPLEX)
      return ["the answer is not valid JSON"] if value.equal?(PARSE_FAILED)

      plan_for(schema).violations(value)
    end

    def fix_prompt(errors)
      lines = errors.map { |error| "- #{error}" }.join("\n")
      "Your answer did not satisfy the required output schema. Problems:\n" \
        "#{lines}\nReply with ONLY the corrected JSON."
    end

    def plan_for(schema)
      return schema if schema.respond_to?(:schema) && schema.respond_to?(:violations)

      Schema.task_plan(schema)
    end
    private_class_method :plan_for
  end
end
