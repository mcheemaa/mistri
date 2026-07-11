# frozen_string_literal: true

module Mistri
  module Providers
    # Keeps provider grammar limits out of task semantics: an incompatible
    # native schema is omitted while the prompt and local validator stay exact.
    module SchemaCapabilities
      COMMON_KEYWORDS = %w[
        type properties required additionalProperties items enum description
      ].freeze
      PROFILES = {
        openai: {
          keywords: COMMON_KEYWORDS,
          root_object: true,
          boolean_schemas: false,
          tuple_arrays: false,
          all_properties_required: true,
          max_depth: 10,
          max_properties: 5000,
          max_enum_values: 1000,
          max_schema_string_chars: 120_000,
          large_enum_threshold: 250,
          max_large_enum_chars: 15_000
        }.freeze,
        anthropic: {
          keywords: COMMON_KEYWORDS,
          root_object: false,
          boolean_schemas: false,
          tuple_arrays: false,
          all_properties_required: false,
          max_optional_properties: 24
        }.freeze,
        gemini: {
          keywords: (COMMON_KEYWORDS + %w[prefixItems format title]).freeze,
          root_object: false,
          boolean_schemas: true,
          tuple_arrays: true,
          all_properties_required: false,
          formats: %w[date-time date time].freeze,
          enum_types: %w[string number integer].freeze
        }.freeze
      }.freeze

      module_function

      def derive(schema, provider)
        profile = PROFILES.fetch(provider)
        state = { properties: 0, optional_properties: 0, enum_values: 0,
                  schema_string_chars: 0 }
        return unless supported?(schema, profile, state, root: true, depth: 0)

        schema
      end

      def supported?(schema, profile, state, depth:, root: false)
        return profile[:boolean_schemas] if schema.equal?(true) || schema.equal?(false)
        return false unless schema_shape_supported?(schema, profile)

        type = schema["type"]
        depth += 1 if %w[object array].include?(type)
        return false unless node_supported?(schema, type, profile, state, root:, depth:)

        child_schemas(schema).all? do |member|
          supported?(member, profile, state, depth:)
        end
      end
      private_class_method :supported?

      def schema_shape_supported?(schema, profile)
        schema.is_a?(Hash) && schema["type"].is_a?(String) &&
          (schema.keys - profile[:keywords]).empty?
      end
      private_class_method :schema_shape_supported?

      def node_supported?(schema, type, profile, state, root:, depth:)
        within_limit?(depth, profile[:max_depth]) &&
          root_supported?(type, profile, root) &&
          object_supported?(schema, type, profile, state) &&
          array_supported?(schema, type, profile) &&
          format_supported?(schema, type, profile) &&
          enum_supported?(schema, type, profile, state)
      end
      private_class_method :node_supported?

      def root_supported?(type, profile, root)
        !root || !profile[:root_object] || type == "object"
      end
      private_class_method :root_supported?

      def object_supported?(schema, type, profile, state)
        object_keywords = schema.key?("properties") || schema.key?("required") ||
                          schema.key?("additionalProperties")
        return true unless type == "object" || object_keywords
        return false unless valid_object_shape?(schema, type)

        properties = schema["properties"]
        required = schema["required"]
        return false unless required_properties_declared?(required, properties)

        required_index = required.to_h { |name| [name, true] }
        record_object_limits(state, properties, required_index)
        return false unless object_limits_supported?(state, profile)
        return true unless profile[:all_properties_required]

        required_index.length == properties.length &&
          required_index.each_key.all? { |key| properties.key?(key) }
      end
      private_class_method :object_supported?

      def required_properties_declared?(required, properties)
        required.all? { |name| properties.key?(name) }
      end
      private_class_method :required_properties_declared?

      def valid_object_shape?(schema, type)
        type == "object" && schema["properties"].is_a?(Hash) &&
          schema["required"].is_a?(Array) && schema["additionalProperties"] == false
      end
      private_class_method :valid_object_shape?

      def record_object_limits(state, properties, required)
        state[:properties] += properties.length
        state[:optional_properties] += properties.keys.count { |name| !required.key?(name) }
        state[:schema_string_chars] += properties.keys.sum(&:length)
      end
      private_class_method :record_object_limits

      def object_limits_supported?(state, profile)
        within_limit?(state[:properties], profile[:max_properties]) &&
          within_limit?(state[:optional_properties], profile[:max_optional_properties]) &&
          within_limit?(state[:schema_string_chars], profile[:max_schema_string_chars])
      end
      private_class_method :object_limits_supported?

      def array_supported?(schema, type, profile)
        array_keywords = schema.key?("items") || schema.key?("prefixItems")
        return true unless type == "array" || array_keywords
        return false unless type == "array"
        return false if schema.key?("prefixItems") && !profile[:tuple_arrays]
        return false unless schema.key?("items") || schema.key?("prefixItems")

        true
      end
      private_class_method :array_supported?

      def format_supported?(schema, type, profile)
        return true unless schema.key?("format")

        profile[:formats]&.include?(schema["format"]) && type == "string"
      end
      private_class_method :format_supported?

      def enum_supported?(schema, type, profile, state)
        values = schema["enum"]
        return true unless values
        return false unless values.is_a?(Array)
        return false unless enum_domain_supported?(values, type, profile)

        state[:enum_values] += values.length
        strings = values.grep(String)
        string_chars = strings.sum(&:length)
        state[:schema_string_chars] += string_chars
        return false unless within_limit?(state[:enum_values], profile[:max_enum_values])
        return false unless within_limit?(state[:schema_string_chars],
                                          profile[:max_schema_string_chars])

        threshold = profile[:large_enum_threshold]
        return true unless threshold && values.length > threshold && strings.length == values.length

        string_chars <= profile[:max_large_enum_chars]
      end
      private_class_method :enum_supported?

      def enum_domain_supported?(values, type, profile)
        return true unless profile[:enum_types]
        return false unless profile[:enum_types].include?(type)

        case type
        when "string" then values.all?(String)
        when "number" then values.all? { |value| finite_number?(value) }
        when "integer" then values.all? { |value| integer_number?(value) }
        end
      end
      private_class_method :enum_domain_supported?

      def finite_number?(value)
        value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
      end
      private_class_method :finite_number?

      def integer_number?(value)
        value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value.to_i == value)
      end
      private_class_method :integer_number?

      def within_limit?(value, limit)
        !limit || value <= limit
      end
      private_class_method :within_limit?

      def child_schemas(schema)
        children = schema.fetch("properties", {}).values
        items = schema["items"]
        children << items if items.is_a?(Hash) || items.equal?(true) || items.equal?(false)
        children.concat(schema.fetch("prefixItems", []))
        additional = schema["additionalProperties"]
        children << additional if additional.is_a?(Hash) || additional.equal?(true)
        children
      end
      private_class_method :child_schemas
    end
    private_constant :SchemaCapabilities
  end
end
