# frozen_string_literal: true

require_relative "test_helper"

# Dialect and completeness rules keep public schema promises honest.
class TestSchemaContract < Minitest::Test
  def test_json_schema_2020_12_rejects_legacy_tuple_items
    schema = { type: "array", items: [{ type: "string" }] }

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!(schema)
    end

    assert_match(/JSON Schema 2020-12/, error.message)
    assert_match(/prefixItems/, error.message)
  end

  def test_a_declared_schema_dialect_must_be_json_schema_twenty_twenty_twelve
    schema = { "$schema" => "http://json-schema.org/draft-07/schema#", type: "object" }

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!(schema)
    end

    assert_equal "$.$schema must declare JSON Schema 2020-12", error.message
  end

  def test_schema_byte_limit_covers_json_escaping_and_large_integers
    escaped = { description: "\0" * (2 * 1024 * 1024) }
    integer = { default: 1 << 28_000_000 }

    [escaped, integer].each do |schema|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::Schema.validate_definition!(schema)
      end
      assert_match(/exceeds the schema byte limit/, error.message)
    end
  end

  def test_unsupported_independent_keywords_remain_provider_guidance
    schema = { type: "string", pattern: "^x", minimum: 0.5, format: "custom" }

    assert_same schema, Mistri::Schema.validate_definition!(schema)
    assert_empty Mistri::Schema.violations("value", schema)
    assert_equal ["$.pattern", "$.minimum"].sort,
                 Mistri::Schema.unsupported_assertions(schema).sort
    assert_equal "custom", Mistri::Schema.strict(schema).fetch("format")
  end

  def test_default_dialect_annotations_do_not_claim_validation_semantics
    schema = {
      type: "string",
      format: "email",
      contentSchema: { type: "number", minimum: 1 }
    }
    plan = Mistri::Schema.task_plan(schema)

    assert_empty Mistri::Schema.unsupported_assertions(schema)
    assert_empty plan.violations("not-an-email")

    tool_schema = {
      type: "object",
      properties: {
        payload: {
          type: "string",
          contentSchema: {
            type: "object", patternProperties: { "^x" => { type: "integer" } },
            additionalProperties: false
          }
        }
      }
    }

    Mistri::Schema.tool_validator(tool_schema)
  end

  def test_recognized_json_schema_keywords_validate_their_shapes
    invalid = {
      { description: 1 } => /description must be a string/,
      { deprecated: "yes" } => /deprecated must be a boolean/,
      { format: 1 } => /format must be a string/,
      { minimum: "one" } => /minimum must be a number/,
      { maxLength: -1 } => /maxLength must be a non-negative integer/,
      { multipleOf: 0 } => /multipleOf must be a number greater than zero/,
      { dependentRequired: [] } => /dependentRequired must be an object/,
      { dependentRequired: { kind: %w[value value] } } =>
        /dependentRequired.kind must be an array of unique strings/,
      { "$ref" => 1 } => /\$ref must be a URI-reference string/,
      { "$anchor" => "not/a-name" } => /\$anchor must be a valid plain-name anchor/,
      { "$vocabulary" => [] } => /\$vocabulary must map URI strings to booleans/,
      { examples: {} } => /examples must be an array/
    }

    invalid.each do |schema, message|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::Schema.validate_definition!(schema)
      end
      assert_match message, error.message
    end
  end

  def test_schema_identifiers_reject_nonempty_fragments
    Mistri::Schema.validate_definition!({ "$id" => "record#", type: "string" })

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Schema.validate_definition!({ "$id" => "record#member", type: "string" })
    end

    assert_equal "$.$id must not contain a non-empty fragment", error.message
  end

  def test_vocabulary_keys_are_absolute_normalized_uris
    valid = { "$vocabulary" => { "https://example.test/vocab" => false }, type: "string" }
    Mistri::Schema.validate_definition!(valid)

    ["relative-vocab", "HTTPS://EXAMPLE.TEST/vocab"].each do |uri|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::Schema.validate_definition!({ "$vocabulary" => { uri => false } })
      end

      assert_equal "$.$vocabulary must use absolute normalized URI keys", error.message
    end
  end

  def test_inline_vocabulary_declarations_are_not_instance_assertions
    required = {
      "$vocabulary" => { "https://example.test/vocab" => true }, type: "string"
    }
    optional = {
      "$vocabulary" => { "https://example.test/vocab" => false }, type: "string"
    }

    Mistri::Schema.task_plan(required)
    Mistri::Schema.task_plan(optional)

    assert_empty Mistri::Schema.unsupported_assertions(required)
  end

  def test_tool_schemas_require_an_object_root
    [false, true, { type: "string" }, { type: %w[object null] }].each do |schema|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::Schema.tool_validator(schema)
      end

      assert_equal "$ must declare type object for tool arguments", error.message
    end
  end

  def test_open_pattern_properties_also_require_complete_validation
    schema = {
      type: "object",
      patternProperties: { "^x-" => { type: "integer" } }
    }

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Tool.define("patterned", "Patterned.", input_schema: schema) { "ran" }
    end

    assert_match(/non-empty pattern properties require a complete argument validator/,
                 error.message)
    tool = Mistri::Tool.define(
      "patterned",
      "Patterned.",
      input_schema: schema,
      complete_argument_validator: ->(*) { [] }
    ) { "ran" }

    assert_empty tool.argument_violations("x-count" => "host validates this")
  end

  def test_task_plan_rejects_assertions_local_validation_cannot_enforce
    schema = {
      type: "object",
      properties: { code: { type: "string", pattern: "\\A[a-z]+\\z" } }
    }

    error = assert_raises(Mistri::ConfigurationError) { Mistri::Schema.task_plan(schema) }

    assert_match(/task output schema uses assertions Mistri cannot validate/, error.message)
    assert_match(/\$\.properties\.code\.pattern/, error.message)
  end

  def test_strict_compiles_before_walking_a_cyclic_schema
    schema = { type: "object" }
    schema[:properties] = { child: schema }

    error = assert_raises(Mistri::ConfigurationError) { Mistri::Schema.strict(schema) }

    assert_match(/contains a cycle/, error.message)
  end

  def test_task_plan_owns_one_strict_schema_for_provider_and_local_validation
    source = {
      type: "object",
      properties: { code: { type: "string" } },
      required: ["code"]
    }
    plan = Mistri::Schema.task_plan(source)
    source[:properties][:code][:type] = "integer"

    assert_predicate plan.schema, :frozen?
    assert_predicate plan.schema.fetch("properties").fetch("code"), :frozen?
    assert_equal "string", plan.schema.dig("properties", "code", "type")
    refute plan.schema.fetch("additionalProperties")
    assert_empty plan.violations("code" => "ok")
    assert_equal ["$.extra is not allowed"],
                 plan.violations("code" => "ok", "extra" => true)
  end
end
