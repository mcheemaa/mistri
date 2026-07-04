# frozen_string_literal: true

module Mistri
  # A small builder for tool argument schemas, so a tool declares its inputs
  # in Ruby instead of hand-writing JSON Schema. It emits the object schema
  # every provider accepts:
  #
  #   Schema.build do
  #     string :city, "City name", required: true
  #     string :units, "Temperature units", enum: %w[celsius fahrenheit]
  #     integer :days, "Forecast length"
  #   end
  #
  # A raw JSON Schema hash is always accepted directly for anything the
  # builder does not cover, so the DSL is a convenience, never a ceiling.
  class Schema
    # instance_exec, not instance_eval: it binds self to the builder without
    # passing an argument, so a zero-arity lambda works as naturally as a proc.
    def self.build(&)
      builder = new
      builder.instance_exec(&)
      builder.to_h
    end

    def initialize
      @properties = {}
      @required = []
    end

    %i[string integer number boolean].each do |type|
      define_method(type) do |name, description = nil, required: false, enum: nil, **extra|
        prop = { type: type.to_s }
        prop[:description] = description if description
        prop[:enum] = enum if enum
        @properties[name.to_s] = prop.merge(extra)
        @required << name.to_s if required
        nil
      end
    end

    def array(name, description = nil, items: { type: "string" }, required: false, **extra)
      prop = { type: "array", items: items }
      prop[:description] = description if description
      @properties[name.to_s] = prop.merge(extra)
      @required << name.to_s if required
      nil
    end

    def object(name, description = nil, required: false, &)
      prop = self.class.build(&)
      prop[:description] = description if description
      @properties[name.to_s] = prop
      @required << name.to_s if required
      nil
    end

    def to_h
      schema = { type: "object", properties: @properties }
      schema[:required] = @required unless @required.empty?
      schema
    end

    class << self
      # Violations of a value against the schema subset the harness emits and
      # providers constrain: types (including type arrays), object properties
      # with required and additionalProperties: false, array items, enum.
      # Empty means valid; entries are human-readable, written to be fed back
      # to a model for one-shot correction.
      def violations(value, schema, path = "$")
        spec = schema.transform_keys(&:to_s)
        mismatch = type_violation(value, spec, path)
        return [mismatch] if mismatch

        errors = []
        if (enum = spec["enum"]) && !enum.include?(value)
          errors << "#{path} must be one of: #{enum.join(", ")}"
        end
        case value
        when Hash then errors.concat(object_violations(value, spec, path))
        when Array then errors.concat(array_violations(value, spec, path))
        end
        errors
      end

      # Prepares a schema for constrained decoding: every object gains
      # additionalProperties: false (Anthropic and OpenAI both demand it),
      # and all_required marks every property required (OpenAI strict mode's
      # rule). String keys throughout, ready for the wire.
      def strict(schema, all_required: false)
        spec = schema.transform_keys(&:to_s)
        out = spec.dup
        if spec["type"] == "object" || spec.key?("properties")
          props = (spec["properties"] || {}).to_h do |key, member|
            [key.to_s, strict(member, all_required: all_required)]
          end
          out["properties"] = props
          out["additionalProperties"] = false
          out["required"] = all_required ? props.keys : Array(spec["required"]).map(&:to_s)
        end
        if spec["items"].is_a?(Hash)
          out["items"] =
            strict(spec["items"], all_required: all_required)
        end
        out
      end

      TYPES = {
        "object" => ->(v) { v.is_a?(Hash) }, "array" => ->(v) { v.is_a?(Array) },
        "string" => ->(v) { v.is_a?(String) }, "integer" => ->(v) { v.is_a?(Integer) },
        "number" => ->(v) { v.is_a?(Numeric) }, "boolean" => ->(v) { [true, false].include?(v) },
        "null" => lambda(&:nil?)
      }.freeze

      private

      def type_violation(value, spec, path)
        names = Array(spec["type"]).map(&:to_s)
        return nil if names.empty?
        return nil if names.any? { |name| TYPES.fetch(name, ->(_) { true }).call(value) }

        "#{path} must be #{names.join(" or ")}, got #{json_type(value)}"
      end

      def object_violations(value, spec, path)
        props = (spec["properties"] || {}).transform_keys(&:to_s)
        errors = Array(spec["required"]).map(&:to_s).filter_map do |key|
          "#{path}.#{key} is required" unless value.key?(key)
        end
        value.each do |key, member|
          if (member_schema = props[key.to_s])
            errors.concat(violations(member, member_schema, "#{path}.#{key}"))
          elsif spec["additionalProperties"] == false
            errors << "#{path}.#{key} is not allowed"
          end
        end
        errors
      end

      def array_violations(value, spec, path)
        items = spec["items"]
        return [] unless items.is_a?(Hash)

        value.each_with_index.flat_map do |member, index|
          violations(member, items, "#{path}[#{index}]")
        end
      end

      def json_type(value)
        case value
        when Hash then "object"
        when Array then "array"
        when String then "string"
        when Integer then "integer"
        when Numeric then "number"
        when true, false then "boolean"
        when nil then "null"
        else value.class.name
        end
      end
    end
  end
end
