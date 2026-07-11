# frozen_string_literal: true

require_relative "test_helper"

# Schema.violations and Schema.strict: the client-side halves of structured
# output: validation everywhere, wire preparation for constrained decoding.
class TestSchemaValidate < Minitest::Test
  SCHEMA = {
    type: "object",
    properties: {
      "name" => { type: "string" },
      "tiers" => { type: "array",
                   items: { type: "object",
                            properties: { "price" => { type: "number" },
                                          "label" => { type: "string",
                                                       enum: %w[basic pro] } },
                            required: ["price"] } },
      "count" => { type: "integer" },
      "note" => { type: %w[string null] }
    },
    required: %w[name tiers]
  }.freeze

  def test_a_conforming_value_has_no_violations
    value = { "name" => "Pricing", "count" => 2, "note" => nil,
              "tiers" => [{ "price" => 9.5, "label" => "basic" }] }

    assert_empty Mistri::Schema.violations(value, SCHEMA)
  end

  def test_violations_name_the_path_and_the_problem
    value = { "tiers" => [{ "label" => "enterprise" }], "count" => "three" }
    errors = Mistri::Schema.violations(value, SCHEMA)

    assert_includes errors, "$.name is required"
    assert_includes errors, "$.tiers[0].price is required"
    assert_includes errors, "$.tiers[0].label must match enum"
    assert_includes errors, "$.count must be integer, got string"
    refute(errors.any? { |message| message.include?("basic") || message.include?("enterprise") })
  end

  def test_type_arrays_allow_null
    assert_empty Mistri::Schema.violations({ "name" => "x", "tiers" => [], "note" => nil },
                                           SCHEMA)
    errors = Mistri::Schema.violations({ "name" => "x", "tiers" => [], "note" => 7 }, SCHEMA)

    assert_includes errors, "$.note must be string or null, got integer"
  end

  def test_integer_counts_as_number_but_not_the_reverse
    schema = { type: "object", properties: { "price" => { type: "number" } } }

    assert_empty Mistri::Schema.violations({ "price" => 3 }, schema)
    assert_empty Mistri::Schema.violations(1.0, { type: "integer" })
    refute_empty Mistri::Schema.violations(
      { "count" => 3.5 },
      { type: "object", properties: { "count" => { type: "integer" } } }
    )
  end

  def test_type_failures_name_each_json_runtime_type
    schema = { type: "string" }

    assert_equal ["$ must be string, got object"], Mistri::Schema.violations({}, schema)
    assert_equal ["$ must be string, got boolean"], Mistri::Schema.violations(true, schema)
    assert_equal ["$ must be string, got null"], Mistri::Schema.violations(nil, schema)
    assert_empty Mistri::Schema.violations(true, { type: "boolean" })
    assert_empty Mistri::Schema.violations(false, { type: "boolean" })
  end

  def test_non_json_numerics_do_not_satisfy_number_types
    schema = { type: "number" }

    [Float::NAN, Float::INFINITY, Rational(3, 2)].each do |value|
      assert_equal ["$ must be valid JSON"],
                   Mistri::Schema.violations(value, schema)
    end
  end

  def test_boolean_schemas_work_at_any_supported_location
    schema = {
      type: "object",
      properties: { "anything" => true, "forbidden" => false,
                    "tail" => { type: "array", items: false } }
    }
    value = { "anything" => { "nested" => [1, true, nil] },
              "forbidden" => "secret", "tail" => [1] }

    assert_equal ["$.forbidden is not allowed", "$.tail[0] is not allowed"],
                 Mistri::Schema.violations(value, schema)
    assert_empty Mistri::Schema.violations("anything", true)
    assert_equal ["$ is not allowed"], Mistri::Schema.violations("anything", false)
  end

  def test_true_schema_still_rejects_non_json_ruby_values
    invalid_utf8 = "\xFF".b

    assert_equal ["$ must be valid JSON"], Mistri::Schema.violations(Object.new, true)
    assert_empty Mistri::Schema.violations({ symbol: "key" }, true)
    assert_equal ["$ must be valid JSON"], Mistri::Schema.violations(invalid_utf8, true)
  end

  def test_instance_and_schema_cycles_fail_closed
    value = {}
    value["self"] = value
    schema = { type: "object" }
    schema[:properties] = { "self" => schema }

    assert_equal ["$ must be valid JSON"], Mistri::Schema.violations(value, true)
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!(schema)
    end
    assert_match(/contains a cycle/, error.message)
  end

  def test_type_unions_are_nonempty_and_contain_only_known_types
    empty = assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!({ type: [] })
    end
    unknown = assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.violations("x", { type: %w[string mystery] })
    end

    assert_equal "$.type must be a primitive or non-empty union", empty.message
    assert_equal "$.type contains an unknown JSON type", unknown.message
  end

  def test_enum_uses_json_value_equality
    schema = { enum: [{ "enabled" => true, "limits" => { "daily" => 1 } }] }
    reordered = { "limits" => { "daily" => 1.0 }, "enabled" => true }

    assert_empty Mistri::Schema.violations(reordered, schema)
    assert_equal ["$ must match enum"], Mistri::Schema.violations(1, { enum: [true] })
  end

  def test_items_begin_after_prefix_items
    schema = {
      type: "array",
      prefixItems: [{ type: "string" }, true],
      items: { type: "string" }
    }

    assert_empty Mistri::Schema.violations(["head", nil, "tail"], schema)
    assert_equal ["$[0] must be string, got integer",
                  "$[3] must be string, got integer"],
                 Mistri::Schema.violations([7, nil, "tail", 4], schema)
  end

  def test_additional_properties_false_rejects_strays
    schema = { type: "object", properties: { "a" => { type: "string" } },
               additionalProperties: false }

    assert_equal ["$.b is not allowed"], Mistri::Schema.violations({ "a" => "x", "b" => 1 }, schema)
  end

  def test_paths_escape_and_bound_hostile_property_names
    hostile = "line\n\"quote"
    errors = Mistri::Schema.violations({ hostile => 1 },
                                       { type: "object", additionalProperties: false })
    long_errors = Mistri::Schema.violations({ "x" * 65_536 => 1 },
                                            { type: "object", additionalProperties: false })

    assert_equal ["$[\"line\\n\\\"quote\"] is not allowed"], errors
    refute_includes errors.first, "\n"
    assert_operator long_errors.first.bytesize, :<=, 280
  end

  def test_violations_stop_at_the_public_error_limit
    schema = { type: "object", required: (1..20).map { |index| "key#{index}" } }
    errors = Mistri::Schema.violations({}, schema)

    assert_equal 8, errors.length
    assert_equal "$.key1 is required", errors.first
    assert_equal "$ additional violations omitted", errors.last
  end

  def test_validation_bounds_values_even_without_nested_assertions
    errors = Mistri::Schema.violations(Array.new(10_001), { type: "array" })

    assert_equal 1, errors.length
    assert_match(/validation limit exceeded/, errors.first)

    arguments = Mistri.const_get(:ToolArguments, false)
    huge_integer = 1 << ((arguments::MAX_NUMBER_BYTES + 1) * 4)

    assert_equal ["$ validation limit exceeded"],
                 Mistri::Schema.violations(huge_integer, { type: "integer" })
  end

  def test_general_validation_does_not_guess_pattern_semantics
    schema = {
      type: "object",
      properties: { "declared" => { type: "string" } },
      patternProperties: { "^x-" => { type: "integer" } },
      additionalProperties: false
    }

    assert_same schema, Mistri::Schema.validate_definition!(schema)
    assert_equal ["$.declared must be string, got integer"],
                 Mistri::Schema.violations(
                   { "declared" => 1, "x-valid" => 2, "unknown" => 3 },
                   schema
                 )
  end

  def test_empty_pattern_properties_do_not_weaken_a_closed_object
    schema = { type: "object", patternProperties: {}, additionalProperties: false }

    assert_same schema, Mistri::Schema.validate_definition!(schema)
    assert_equal ["$.unknown is not allowed"],
                 Mistri::Schema.violations({ "unknown" => 1 }, schema)
  end

  def test_closed_pattern_properties_validate_the_interaction_shape
    schema = { type: "object", patternProperties: [], additionalProperties: false }

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!(schema)
    end

    assert_equal "$.patternProperties must be an object", error.message
  end

  def test_schema_valued_additional_properties_are_portable
    additional = { type: "object", additionalProperties: { type: "string" } }

    assert_same additional, Mistri::Schema.validate_definition!(additional)
    assert_empty Mistri::Schema.violations({ "raw" => "value" }, additional)
    assert_equal ["$.raw must be string, got integer"],
                 Mistri::Schema.violations({ "raw" => 1 }, additional)
  end

  def test_malformed_supported_keyword_shapes_fail_at_definition
    schemas = [
      { type: nil },
      { type: %w[string string] },
      { enum: "x" },
      { enum: [Float::NAN] },
      { enum: [Object.new] },
      { properties: [] },
      { properties: { a: true, "a" => true } },
      { required: "x" },
      { required: %w[x x] },
      { items: "x" },
      { items: {}, prefixItems: "x" },
      { additionalProperties: nil },
      { 1 => true },
      { description: "\xFF".b }
    ]

    schemas.each do |schema|
      assert_raises(Mistri::ConfigurationError, schema.inspect) do
        Mistri::Schema.validate_definition!(schema)
      end
    end
  end

  def test_schema_document_keywords_validate_their_subschemas
    schema = {
      "$schema" => Mistri::Schema::DIALECT,
      "$defs" => { identifier: { type: :string } },
      definitions: { legacy: true },
      dependentSchemas: { kind: { required: ["value"] } },
      allOf: [true],
      anyOf: [{ not: false }],
      oneOf: [{ if: true, then: true, else: false }],
      contains: { type: "integer" },
      propertyNames: { type: "string" },
      unevaluatedProperties: true,
      unevaluatedItems: false,
      contentSchema: { type: "string" },
      default: 1.5
    }

    assert_same schema, Mistri::Schema.validate_definition!(schema)

    invalid = {
      { "$defs" => [] } => "$.$defs must be an object",
      { allOf: [] } => "$.allOf must be a non-empty array of schemas",
      { not: [] } => "$.not must be a schema object or boolean",
      { allOf: [{ required: %w[x x] }] } =>
        "$.allOf[0].required must be an array of unique strings"
    }
    invalid.each do |definition, message|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::Schema.validate_definition!(definition)
      end
      assert_equal message, error.message
    end
  end

  def test_schema_definitions_are_resource_bounded
    too_deep = true
    65.times { too_deep = { not: too_deep } }

    definitions = {
      too_deep => /exceeds the schema depth limit/,
      { "x-extension" => Array.new(10_001, true) } => /exceeds the schema size limit/,
      { description: "x" * (9 * 1024 * 1024) } => /exceeds the schema byte limit/
    }

    definitions.each do |definition, message|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::Schema.validate_definition!(definition)
      end
      assert_match message, error.message
    end
  end

  def test_empty_enum_is_valid_and_rejects_every_instance
    schema = { enum: [] }

    assert_same schema, Mistri::Schema.validate_definition!(schema)
    assert_equal ["$ must match enum"], Mistri::Schema.violations(nil, schema)
  end

  def test_schema_snapshot_matches_json_string_encoding
    utf8 = "é".encode(Encoding::UTF_8)
    utf16 = "é".encode(Encoding::UTF_16LE)
    schema = {
      type: "object",
      properties: { utf16 => { enum: [utf16] } },
      required: [utf16]
    }

    assert_empty Mistri::Schema.violations({ utf8 => utf8 }, schema)
    collision = { properties: { utf8 => true, utf16 => true } }
    assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!(collision)
    end
  end

  def test_definition_limits_cover_ignored_extensions
    cyclic = { type: "object" }
    cyclic["x-extension"] = cyclic

    assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!(cyclic)
    end
    assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!(type: "string", minimum: Object.new)
    end
  end

  def test_the_root_type_is_checked_first
    assert_equal ["$ must be object, got array"], Mistri::Schema.violations([], SCHEMA)
  end

  def test_strict_closes_every_object_recursively
    strict = Mistri::Schema.strict(SCHEMA)

    refute strict["additionalProperties"]
    refute strict.dig("properties", "tiers", "items", "additionalProperties")
    assert_equal %w[name tiers], strict["required"]
  end

  def test_strict_all_required_marks_every_key
    strict = Mistri::Schema.strict(SCHEMA, all_required: true)

    assert_equal %w[name tiers count note], strict["required"]
    assert_equal %w[price label], strict.dig("properties", "tiers", "items", "required")
  end

  def test_strict_rejects_a_freeform_object_instead_of_closing_it
    schema = {
      type: "object",
      properties: { "config" => { type: "object", properties: {} } }
    }

    error = assert_raises(Mistri::ConfigurationError) { Mistri::Schema.strict(schema) }

    assert_equal "$.config is freeform and cannot be represented by a strict schema", error.message
  end

  def test_strict_rejects_explicit_open_objects
    schema = {
      type: "object",
      properties: { "metadata" => { type: "object", properties: { "name" => {
        type: "string"
      } }, additionalProperties: true } }
    }

    error = assert_raises(Mistri::ConfigurationError) { Mistri::Schema.strict(schema) }

    assert_equal "$.metadata is open and cannot be represented by a strict schema", error.message
  end

  def test_strict_preserves_an_explicitly_closed_empty_object
    schema = { type: "object", properties: {}, additionalProperties: false }

    assert_equal({ "type" => "object", "properties" => {},
                   "additionalProperties" => false, "required" => [] },
                 Mistri::Schema.strict(schema))
  end

  def test_strict_preserves_boolean_schemas
    assert Mistri::Schema.strict(true)
    refute Mistri::Schema.strict(false)
    assert_equal({ "type" => "object", "properties" => { "value" => false },
                   "additionalProperties" => false, "required" => [] },
                 Mistri::Schema.strict({ type: "object", properties: { value: false } }))
  end

  def test_strict_closes_objects_inside_tuple_prefixes
    schema = {
      type: "array",
      prefixItems: [{ type: "object", properties: { name: { type: "string" } } }],
      items: false
    }
    strict = Mistri::Schema.strict(schema)

    assert_same false, strict["items"]
    assert_same false, strict.dig("prefixItems", 0, "additionalProperties")
  end
end
