# frozen_string_literal: true

require "json"
require "uri"

require_relative "tool_arguments"

module Mistri
  # Builds tool schemas and validates the portable JSON Schema subset Mistri owns.
  class Schema
    DIALECT = "https://json-schema.org/draft/2020-12/schema"
    MAX_VIOLATIONS = 8
    MAX_DEPTH = 64
    MAX_NODES = 10_000
    MAX_BYTES = 8 * 1024 * 1024
    JSON_TYPES = %w[object array string integer number boolean null].freeze

    # instance_exec binds self to the builder without passing an argument, so
    # zero-arity lambdas and procs behave the same way.
    def self.build(&block)
      raise ConfigurationError, "schema needs a block" unless block

      builder = new
      builder.instance_exec(&block)
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

    def object(name, description = nil, required: false, &block)
      prop = block ? self.class.build(&block) : self.class.new.to_h
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
      # Definition checks cover the complete JSON document. Unsupported
      # assertion keywords remain provider guidance in this general API.
      def validate_definition!(schema)
        Compiled.new(schema)
        schema
      end

      # Returns bounded, model-readable failures for the subset Mistri owns:
      # type, enum, required, properties, additionalProperties, items, and
      # prefixItems. The input is first normalized to the JSON value providers see.
      def violations(value, schema, path = "$")
        Compiled.new(schema).violations(value, path)
      end

      # A Tool keeps this plan for its lifetime. complete is explicit authority
      # for a host validator to own schema interactions core cannot represent.
      def tool_validator(schema, complete: false)
        Compiled.new(schema, tool: true, complete: complete)
      end

      # MCP schemas get the same stance as host-authored tools: the portable
      # subset is enforced locally and other standard assertions stay provider
      # guidance, because the MCP spec already obligates the server to validate
      # its own tool inputs. strict: true refuses any contract core cannot
      # enforce; complete: true hands the whole contract to the host validator.
      # External references are rejected in every mode.
      def validate_mcp!(schema, complete: false, strict: false)
        compiled = Compiled.new(schema, tool: true, complete: complete)
        AssertionContract.new(complete:, context: "MCP input schema",
                              enforce: strict).call(compiled.schema)
        compiled.schema
      end

      # Paths to standard assertions that the zero-dependency validator does
      # not implement. An empty list means local validation owns the contract.
      def unsupported_assertions(schema)
        compiled = Compiled.new(schema)
        AssertionScanner.new.call(compiled.schema).map(&:first).freeze
      end

      # Task mode validates only schemas whose complete assertion contract is
      # implemented locally; provider constrained decoding is an optimization.
      def task_violations(value, schema, path = "$")
        task_plan(schema).violations(value, path)
      end

      # One task plan owns the strict prompt and validation schema. Providers
      # may derive a compatible native constraint, but local validation remains
      # the guarantee when their structured-output subset is narrower.
      def task_plan(schema, all_required: false)
        source = compile_task_schema(schema)
        strict = strict_at(source.schema, all_required:, path: "$")
        TaskPlan.new(Compiled.new(strict))
      end

      # Prepares a schema for constrained decoding without turning a freeform
      # object into one that accepts only {}. Definition compilation happens
      # first so recursive transformation never sees a cyclic or hostile graph.
      def strict(schema, all_required: false)
        source = Compiled.new(schema)
        strict_at(source.schema, all_required:, path: "$")
      end

      private

      def compile_task_schema(schema)
        compiled = Compiled.new(schema)
        AssertionContract.new(complete: false, context: "task output schema").call(
          compiled.schema
        )
        compiled
      end

      def strict_at(schema, all_required:, path:)
        return schema if schema.equal?(true) || schema.equal?(false)

        spec = schema.transform_keys(&:to_s)
        out = spec.dup
        if spec["type"] == "object" || spec.key?("properties")
          raw_props = spec["properties"] || {}
          reject_open_object!(spec, raw_props, path)
          props = raw_props.to_h do |key, member|
            member_path = "#{path}.#{key}"
            [key.to_s, strict_at(member, all_required: all_required, path: member_path)]
          end.freeze
          out["properties"] = props
          out["additionalProperties"] = false
          required = all_required ? props.keys : Array(spec["required"]).map(&:to_s)
          out["required"] = required.freeze
        end
        if schema_value?(spec["items"])
          out["items"] = strict_at(
            spec["items"], all_required: all_required, path: "#{path}[]"
          )
        end
        strict_prefix_items(spec, out, all_required, path)
        out.freeze
      end

      def strict_prefix_items(spec, out, all_required, path)
        return unless spec["prefixItems"].is_a?(Array)

        out["prefixItems"] = spec["prefixItems"].each_with_index.map do |member, index|
          strict_at(member, all_required: all_required, path: "#{path}[#{index}]")
        end.freeze
      end

      def schema_value?(value)
        value.is_a?(Hash) || value.equal?(true) || value.equal?(false)
      end

      def reject_open_object!(spec, properties, path)
        if spec.key?("additionalProperties") && spec["additionalProperties"] != false
          raise ConfigurationError,
                "#{path} is open and cannot be represented by a strict schema"
        end
        return unless properties.empty? && spec["additionalProperties"] != false

        raise ConfigurationError,
              "#{path} is freeform and cannot be represented by a strict schema"
      end
    end

    # Shared JSON semantics keep definition and instance handling identical.
    module ValidationSupport
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      MAX_KEY_BYTES = 64
      MAX_PATH_BYTES = 240
      MAX_SEGMENT_BYTES = 96

      module_function

      def root_path(path)
        bounded_utf8(path.to_s, MAX_PATH_BYTES).gsub(/[[:cntrl:]]/, "?")
      end

      def child_path(path, key)
        key_text = bounded_utf8(key, MAX_KEY_BYTES)
        segment = key_text.match?(IDENTIFIER) ? ".#{key_text}" : "[#{JSON.generate(key_text)}]"
        segment = "[\"...\"]" if segment.bytesize > MAX_SEGMENT_BYTES
        joined = "#{path}#{segment}"
        joined.bytesize <= MAX_PATH_BYTES ? joined : "$...#{segment}"
      end

      def index_path(path, index)
        segment = "[#{index}]"
        joined = "#{path}#{segment}"
        joined.bytesize <= MAX_PATH_BYTES ? joined : "$...#{segment}"
      end

      def item_path(path) = "#{path}[]"

      def json_number?(value)
        value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
      end

      def json_integer?(value)
        value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value.modulo(1).zero?)
      end

      def json_type(value)
        case value
        when Hash then "object"
        when Array then "array"
        when String then "string"
        when Integer then "integer"
        when Float then "number"
        when true, false then "boolean"
        when nil then "null"
        else "non-JSON value"
        end
      end

      def bounded_utf8(value, max_bytes)
        source = value.to_s
        truncated = source.bytesize > max_bytes
        source = source.byteslice(0, max_bytes) if truncated
        text = source.encode(Encoding::UTF_8, invalid: :replace,
                                              undef: :replace, replace: "?")
        return text if !truncated && text.bytesize <= max_bytes

        prefix = text.byteslice(0, max_bytes - 3).dup.force_encoding(Encoding::UTF_8).scrub
        "#{prefix}..."
      end
      private_class_method :bounded_utf8
    end
    private_constant :ValidationSupport

    # Canonicalization creates the exact immutable JSON document provider
    # serializers receive, preventing encoding and post-definition mutation drift.
    class DefinitionCompiler
      def initialize
        @nodes = 0
        @bytes = 0
        @active = {}.compare_by_identity
      end

      def call(schema)
        owned = copy(schema, "$", 0)
        unless ToolArguments.serialized_size_within_limit?(owned, limit: MAX_BYTES)
          configuration!("$", "exceeds the schema byte limit")
        end
        DefinitionValidator.new.call(owned)
        owned
      end

      private

      def copy(value, path, depth)
        count!(path, depth)
        case value
        when Hash then copy_hash(value, path, depth)
        when Array then copy_array(value, path, depth)
        when String then copy_string(value, path)
        when Symbol then copy_string(value.to_s, path)
        when Integer, true, false, nil then value
        when Float
          configuration!(path, "must contain only finite JSON numbers") unless value.finite?
          value
        else configuration!(path, "must contain only JSON values")
        end
      end

      def copy_hash(value, path, depth)
        within(value, path) do
          value.each_with_object({}) do |(key, member), out|
            unless key.is_a?(String) || key.is_a?(Symbol)
              configuration!(path, "must use string or symbol keys")
            end
            name = copy_string(key.to_s, path)
            configuration!(path, "contains duplicate JSON keys") if out.key?(name)
            out[name] = copy(member, ValidationSupport.child_path(path, name), depth + 1)
          end.freeze
        end
      end

      def copy_array(value, path, depth)
        within(value, path) do
          value.each_with_index.map do |member, index|
            copy(member, ValidationSupport.index_path(path, index), depth + 1)
          end.freeze
        end
      end

      def copy_string(value, path)
        if value.encoding == Encoding::UTF_8
          configuration!(path, "must use valid UTF-8 strings") unless value.valid_encoding?
          string = value.dup
        else
          string = value.encode(Encoding::UTF_8)
        end
        @bytes += string.bytesize
        configuration!(path, "exceeds the schema byte limit") if @bytes > MAX_BYTES
        string.freeze
      rescue EncodingError
        configuration!(path, "must use valid UTF-8 strings")
      end

      def within(value, path)
        configuration!(path, "contains a cycle") if @active[value]

        @active[value] = true
        inserted = true
        yield
      ensure
        @active.delete(value) if inserted
      end

      def count!(path, depth)
        configuration!(path, "exceeds the schema depth limit") if depth > MAX_DEPTH
        @nodes += 1
        configuration!(path, "exceeds the schema size limit") if @nodes > MAX_NODES
      end

      def configuration!(path, problem)
        raise ConfigurationError, "#{path} #{problem}"
      end
    end
    private_constant :DefinitionCompiler

    # Keyword shape checks are distinct from the full-document JSON scan so
    # ignored extensions cannot evade ownership and resource limits.
    class DefinitionValidator
      STRING_KEYWORDS = %w[
        title description pattern format contentEncoding contentMediaType $comment
      ].freeze
      BOOLEAN_KEYWORDS = %w[uniqueItems deprecated readOnly writeOnly].freeze
      NUMBER_KEYWORDS = %w[maximum exclusiveMaximum minimum exclusiveMinimum].freeze
      NONNEGATIVE_INTEGER_KEYWORDS = %w[
        maxLength minLength maxItems minItems maxContains minContains
        maxProperties minProperties
      ].freeze
      URI_KEYWORDS = %w[$id $ref $dynamicRef].freeze
      ANCHOR = /\A[A-Za-z_][-A-Za-z0-9._]*\z/
      SCHEMA_MAPS = %w[$defs definitions dependentSchemas].freeze
      SCHEMA_ARRAYS = %w[allOf anyOf oneOf].freeze
      SCHEMA_VALUES = %w[
        not if then else contains propertyNames unevaluatedProperties
        unevaluatedItems contentSchema
      ].freeze

      def call(schema)
        walk_schema(schema, "$")
        schema
      end

      private

      def walk_schema(schema, path)
        return if schema.equal?(true) || schema.equal?(false)

        configuration!(path, "must be a schema object or boolean") unless schema.is_a?(Hash)
        validate_dialect(schema, path)
        validate_core_keywords(schema, path)
        validate_annotation_keywords(schema, path)
        validate_assertion_shapes(schema, path)
        validate_type(schema, path)
        validate_enum(schema, path)
        validate_required(schema, path)
        validate_schema_map(schema, "properties", path)
        validate_schema_map(schema, "patternProperties", path)
        validate_items(schema, path)
        validate_prefix_items(schema, path)
        validate_additional_properties(schema, path)
        validate_dependent_required(schema, path)
        SCHEMA_MAPS.each { |keyword| validate_schema_map(schema, keyword, path) }
        SCHEMA_ARRAYS.each { |keyword| validate_schema_array(schema, keyword, path) }
        SCHEMA_VALUES.each { |keyword| validate_schema_value(schema, keyword, path) }
      end

      def validate_dialect(spec, path)
        return unless spec.key?("$schema")
        return if spec["$schema"] == DIALECT

        configuration!("#{path}.$schema", "must declare JSON Schema 2020-12")
      end

      def validate_core_keywords(spec, path)
        validate_uri_keywords(spec, path)
        validate_anchor_keywords(spec, path)
        validate_vocabulary(spec, path)
      end

      def validate_uri_keywords(spec, path)
        URI_KEYWORDS.each do |keyword|
          next unless spec.key?(keyword)

          uri = validate_uri_reference(spec[keyword], "#{path}.#{keyword}")
          next unless keyword == "$id" && uri.fragment && !uri.fragment.empty?

          configuration!("#{path}.$id", "must not contain a non-empty fragment")
        end
      end

      def validate_anchor_keywords(spec, path)
        %w[$anchor $dynamicAnchor].each do |keyword|
          next unless spec.key?(keyword)
          next if spec[keyword].is_a?(String) && spec[keyword].match?(ANCHOR)

          configuration!("#{path}.#{keyword}", "must be a valid plain-name anchor")
        end
      end

      def validate_vocabulary(spec, path)
        return unless spec.key?("$vocabulary")

        vocabulary = spec["$vocabulary"]
        unless vocabulary.is_a?(Hash) && vocabulary.values.all? do |required|
                 required.equal?(true) || required.equal?(false)
               end
          configuration!("#{path}.$vocabulary", "must map URI strings to booleans")
        end
        vocabulary.each_key do |uri|
          validate_absolute_normalized_uri(uri, "#{path}.$vocabulary")
        end
      end

      def validate_annotation_keywords(spec, path)
        STRING_KEYWORDS.each do |keyword|
          next unless spec.key?(keyword)
          next if spec[keyword].is_a?(String)

          configuration!("#{path}.#{keyword}", "must be a string")
        end
        BOOLEAN_KEYWORDS.each do |keyword|
          next unless spec.key?(keyword)
          next if spec[keyword].equal?(true) || spec[keyword].equal?(false)

          configuration!("#{path}.#{keyword}", "must be a boolean")
        end
        return unless spec.key?("examples")
        return if spec["examples"].is_a?(Array)

        configuration!("#{path}.examples", "must be an array")
      end

      def validate_assertion_shapes(spec, path)
        NUMBER_KEYWORDS.each do |keyword|
          next unless spec.key?(keyword)
          next if ValidationSupport.json_number?(spec[keyword])

          configuration!("#{path}.#{keyword}", "must be a number")
        end
        NONNEGATIVE_INTEGER_KEYWORDS.each do |keyword|
          next unless spec.key?(keyword)

          value = spec[keyword]
          next if ValidationSupport.json_integer?(value) && value >= 0

          configuration!("#{path}.#{keyword}", "must be a non-negative integer")
        end
        return unless spec.key?("multipleOf")
        return if ValidationSupport.json_number?(spec["multipleOf"]) && spec["multipleOf"].positive?

        configuration!("#{path}.multipleOf", "must be a number greater than zero")
      end

      def validate_uri_reference(value, path)
        configuration!(path, "must be a URI-reference string") unless value.is_a?(String)

        URI.parse(value)
      rescue URI::InvalidURIError
        configuration!(path, "must be a valid URI-reference")
      end

      def validate_absolute_normalized_uri(value, path)
        configuration!(path, "must use absolute normalized URI keys") unless value.is_a?(String)

        uri = URI.parse(value)
        return uri if uri.absolute? && uri.normalize.to_s == value

        configuration!(path, "must use absolute normalized URI keys")
      rescue URI::InvalidURIError
        configuration!(path, "must use absolute normalized URI keys")
      end

      def validate_type(spec, path)
        return unless spec.key?("type")

        raw = spec["type"]
        names = raw.is_a?(Array) ? raw : [raw]
        valid = !names.empty? && names.all?(String)
        configuration!("#{path}.type", "must be a primitive or non-empty union") unless valid
        unknown = names - JSON_TYPES
        configuration!("#{path}.type", "contains an unknown JSON type") unless unknown.empty?
        configuration!("#{path}.type", "must not repeat a JSON type") if names.uniq != names
      end

      def validate_enum(spec, path)
        return unless spec.key?("enum")

        values = spec["enum"]
        configuration!("#{path}.enum", "must be an array") unless values.is_a?(Array)
      end

      def validate_required(spec, path)
        return unless spec.key?("required")

        keys = spec["required"]
        unless keys.is_a?(Array) && keys.all?(String)
          configuration!("#{path}.required", "must be an array of unique strings")
        end
        return if keys.uniq == keys

        configuration!("#{path}.required", "must be an array of unique strings")
      end

      def validate_dependent_required(spec, path)
        return unless spec.key?("dependentRequired")

        dependencies = spec["dependentRequired"]
        unless dependencies.is_a?(Hash)
          configuration!("#{path}.dependentRequired", "must be an object")
        end
        dependencies.each do |key, members|
          next if members.is_a?(Array) && members.all?(String) && members.uniq == members

          member_path = ValidationSupport.child_path("#{path}.dependentRequired", key)
          configuration!(member_path, "must be an array of unique strings")
        end
      end

      def validate_schema_map(spec, keyword, path)
        return unless spec.key?(keyword)

        members = spec[keyword]
        configuration!("#{path}.#{keyword}", "must be an object") unless members.is_a?(Hash)
        members.each do |key, member|
          walk_schema(member, ValidationSupport.child_path("#{path}.#{keyword}", key))
        end
      end

      def validate_schema_array(spec, keyword, path)
        return unless spec.key?(keyword)

        members = spec[keyword]
        unless members.is_a?(Array) && !members.empty?
          configuration!("#{path}.#{keyword}", "must be a non-empty array of schemas")
        end
        members.each_with_index do |member, index|
          walk_schema(member, ValidationSupport.index_path("#{path}.#{keyword}", index))
        end
      end

      def validate_schema_value(spec, keyword, path)
        return unless spec.key?(keyword)

        walk_schema(spec[keyword], "#{path}.#{keyword}")
      end

      def validate_items(spec, path)
        return unless spec.key?("items")

        items = spec["items"]
        if items.is_a?(Array)
          configuration!("#{path}.items",
                         "must be a schema in JSON Schema 2020-12; use prefixItems for tuples")
        end
        walk_schema(items, ValidationSupport.item_path(path))
      end

      def validate_prefix_items(spec, path)
        return unless spec.key?("prefixItems")

        members = spec["prefixItems"]
        unless members.is_a?(Array) && !members.empty?
          configuration!("#{path}.prefixItems", "must be a non-empty array of schemas")
        end
        members.each_with_index do |member, index|
          walk_schema(member, ValidationSupport.index_path("#{path}.prefixItems", index))
        end
      end

      def validate_additional_properties(spec, path)
        return unless spec.key?("additionalProperties")

        walk_schema(spec["additionalProperties"], "#{path}.additionalProperties")
      end

      def configuration!(path, problem)
        raise ConfigurationError, "#{path} #{problem}"
      end
    end
    private_constant :DefinitionValidator

    # Finds standard assertions that the portable validator intentionally
    # leaves to a complete JSON Schema implementation.
    class AssertionScanner
      ASSERTIONS = %w[
        $ref $dynamicRef allOf anyOf oneOf not if then else
        patternProperties dependentSchemas dependentRequired dependencies
        propertyNames unevaluatedProperties unevaluatedItems contains
        multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
        maxLength minLength pattern maxItems minItems uniqueItems
        maxContains minContains maxProperties minProperties const
      ].freeze
      SCHEMA_MAPS = %w[properties patternProperties $defs definitions dependentSchemas].freeze
      SCHEMA_ARRAYS = %w[allOf anyOf oneOf prefixItems].freeze
      SCHEMA_VALUES = %w[
        not if then else contains propertyNames unevaluatedProperties
        unevaluatedItems additionalProperties items
      ].freeze

      def call(schema)
        @findings = []
        walk(schema, "$")
        @findings.freeze
      end

      private

      def walk(schema, path)
        return if schema.equal?(true) || schema.equal?(false)

        record_assertions(schema, path)
        walk_maps(schema, path)
        walk_arrays(schema, path)
        walk_values(schema, path)
      end

      def record_assertions(schema, path)
        ASSERTIONS.each do |keyword|
          next unless schema.key?(keyword)
          next if ignorable_empty_map?(schema, keyword)

          @findings << ["#{path}.#{keyword}".freeze, keyword, schema[keyword]].freeze
        end
        schema.fetch("$vocabulary", {}).each do |uri, required|
          next unless required

          vocabulary_path = ValidationSupport.child_path("#{path}.$vocabulary", uri)
          @findings << [vocabulary_path.freeze, "$vocabulary", uri].freeze
        end
      end

      def ignorable_empty_map?(schema, keyword)
        return false unless %w[
          patternProperties dependentSchemas dependentRequired dependencies
        ].include?(keyword)

        schema[keyword].is_a?(Hash) && schema[keyword].empty?
      end

      def walk_maps(schema, path)
        SCHEMA_MAPS.each do |keyword|
          schema.fetch(keyword, {}).each do |key, member|
            walk(member, ValidationSupport.child_path("#{path}.#{keyword}", key))
          end
        end
      end

      def walk_arrays(schema, path)
        SCHEMA_ARRAYS.each do |keyword|
          Array(schema[keyword]).each_with_index do |member, index|
            walk(member, ValidationSupport.index_path("#{path}.#{keyword}", index))
          end
        end
      end

      def walk_values(schema, path)
        SCHEMA_VALUES.each do |keyword|
          member = schema[keyword]
          walk(member, "#{path}.#{keyword}") if member.is_a?(Hash)
        end
      end
    end
    private_constant :AssertionScanner

    # Unsupported assertions are safe as generation guidance, but not as a
    # claimed validation boundary; enforce is the caller's stance on refusing
    # them outright. External references are rejected in every mode so
    # validation never implies hidden network or file resolution.
    class AssertionContract
      def initialize(complete:, context:, enforce: true)
        @complete = complete
        @context = context
        @enforce = enforce
      end

      def call(schema)
        findings = AssertionScanner.new.call(schema)
        reject_external_references(findings)
        return if @complete || !@enforce || findings.empty?

        paths = findings.first(3).map(&:first).join(", ")
        suffix = findings.length > 3 ? ", and #{findings.length - 3} more" : ""
        raise ConfigurationError,
              "#{@context} uses assertions Mistri cannot validate at #{paths}#{suffix}"
      end

      private

      def reject_external_references(findings)
        finding = findings.find do |(_, keyword, value)|
          %w[$ref $dynamicRef].include?(keyword) && !value.start_with?("#")
        end
        return unless finding

        raise ConfigurationError,
              "#{finding.first} must be a same-document reference beginning with #"
      end
    end
    private_constant :AssertionContract

    # Core never approximates regex-key semantics. A full validator is explicit
    # authority whenever patternProperties can match an argument key.
    class ToolContract
      def initialize(complete:)
        @complete = complete
      end

      def call(schema)
        unless schema.is_a?(Hash) && schema["type"] == "object"
          configuration!("$", "must declare type object for tool arguments")
        end

        walk(schema, "$")
      end

      private

      def walk(schema, path)
        return if schema.equal?(true) || schema.equal?(false)

        require_complete_for_patterns(schema, path)
        each_subschema(schema, path) { |member, member_path| walk(member, member_path) }
      end

      def require_complete_for_patterns(spec, path)
        patterns = spec["patternProperties"]
        return unless patterns.is_a?(Hash) && !patterns.empty?
        return if @complete

        configuration!("#{path}.patternProperties",
                       "non-empty pattern properties require a complete argument validator")
      end

      def each_subschema(spec, path, &block)
        %w[properties patternProperties $defs definitions dependentSchemas].each do |keyword|
          spec.fetch(keyword, {}).each do |key, member|
            block.call(member, ValidationSupport.child_path("#{path}.#{keyword}", key))
          end
        end
        %w[allOf anyOf oneOf prefixItems].each do |keyword|
          Array(spec[keyword]).each_with_index do |member, index|
            block.call(member, ValidationSupport.index_path("#{path}.#{keyword}", index))
          end
        end
        %w[
          not if then else contains propertyNames unevaluatedProperties
          unevaluatedItems additionalProperties
        ].each do |keyword|
          member = spec[keyword]
          block.call(member, "#{path}.#{keyword}") if member.is_a?(Hash)
        end
        items = spec["items"]
        block.call(items, ValidationSupport.item_path(path)) if items.is_a?(Hash)
      end

      def configuration!(path, problem)
        raise ConfigurationError, "#{path} #{problem}"
      end
    end
    private_constant :ToolContract

    # One immutable validation plan is reused for every call to a Tool.
    class Compiled
      attr_reader :schema

      def initialize(schema, tool: false, complete: false)
        @schema = DefinitionCompiler.new.call(schema)
        ToolContract.new(complete: complete).call(@schema) if tool
        freeze
      end

      def violations(value, path = "$", owned: false)
        unless owned
          value, error = ToolArguments.canonicalize(value)
          if ToolArguments.resource_error?(error)
            return ["#{ValidationSupport.root_path(path)} validation limit exceeded"]
          end
          return ["#{ValidationSupport.root_path(path)} must be valid JSON"] if error
        end
        PortableValidator.new.call(value, @schema, path)
      end
    end
    private_constant :Compiled

    # A task's prompt and local validator share one immutable schema. The marker
    # lets providers omit native constraints they cannot represent faithfully.
    class TaskPlan
      attr_reader :schema

      def initialize(validator)
        @validator = validator
        @schema = validator.schema
        freeze
      end

      def violations(value, path = "$")
        @validator.violations(value, path)
      end

      def native_fallback? = true
    end
    private_constant :TaskPlan

    # Runtime validation is deliberately smaller than JSON Schema. It never
    # approximates pattern semantics; a Tool requiring them supplies a full validator.
    class PortableValidator
      TYPES = {
        "object" => ->(value) { value.is_a?(Hash) },
        "array" => ->(value) { value.is_a?(Array) },
        "string" => ->(value) { value.is_a?(String) },
        "integer" => ->(value) { ValidationSupport.json_integer?(value) },
        "number" => ->(value) { ValidationSupport.json_number?(value) },
        "boolean" => ->(value) { value.equal?(true) || value.equal?(false) },
        "null" => lambda(&:nil?)
      }.freeze

      def initialize
        @errors = []
        @root_path = "$"
        @truncated = false
      end

      def call(value, schema, path)
        @root_path = ValidationSupport.root_path(path)
        walk(value, schema, @root_path)
        @errors
      end

      private

      def walk(value, schema, path)
        return if full? || schema.equal?(true)
        return add("#{path} is not allowed") if schema.equal?(false)

        mismatch = type_violation(value, schema, path)
        return add(mismatch) if mismatch

        enum = schema["enum"]
        add("#{path} must match enum") if enum && !enum.include?(value)
        return if full?

        object_violations(value, schema, path) if value.is_a?(Hash)
        array_violations(value, schema, path) if value.is_a?(Array)
      end

      def type_violation(value, spec, path)
        return unless spec.key?("type")

        names = spec["type"].is_a?(Array) ? spec["type"] : [spec["type"]]
        return if names.any? { |name| TYPES.fetch(name).call(value) }

        "#{path} must be #{names.join(" or ")}, got #{ValidationSupport.json_type(value)}"
      end

      def object_violations(value, spec, path)
        properties = spec.fetch("properties", {})
        spec.fetch("required", []).each do |key|
          add("#{ValidationSupport.child_path(path, key)} is required") unless value.key?(key)
          break if full?
        end
        return if full?

        value.each do |key, member|
          if properties.key?(key)
            walk(member, properties[key], ValidationSupport.child_path(path, key))
          else
            validate_additional(member, key, spec, path)
          end
          break if full?
        end
      end

      def validate_additional(member, key, spec, path)
        additional = spec.fetch("additionalProperties", true)
        patterns = spec["patternProperties"]
        return if patterns.is_a?(Hash) && !patterns.empty? && additional != true
        return if additional.equal?(true)

        member_path = ValidationSupport.child_path(path, key)
        if additional.equal?(false)
          add("#{member_path} is not allowed")
        else
          walk(member, additional, member_path)
        end
      end

      def array_violations(value, spec, path)
        prefix = spec.fetch("prefixItems", [])
        prefix.each_with_index do |member_schema, index|
          break if index >= value.length

          walk(value[index], member_schema, ValidationSupport.index_path(path, index))
          break if full?
        end
        return if full?

        items = spec["items"]
        return unless items.is_a?(Hash) || items.equal?(true) || items.equal?(false)

        index = prefix.length
        while index < value.length
          walk(value[index], items, ValidationSupport.index_path(path, index))
          return if full?

          index += 1
        end
      end

      def add(message)
        if @errors.length < MAX_VIOLATIONS - 1
          @errors << message
        else
          @errors << "#{@root_path} additional violations omitted"
          @truncated = true
        end
      end

      def full? = @truncated
    end
    private_constant :PortableValidator, :MAX_VIOLATIONS, :MAX_DEPTH, :MAX_NODES,
                     :MAX_BYTES, :JSON_TYPES
  end
end
