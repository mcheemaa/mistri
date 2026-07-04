# frozen_string_literal: true

require_relative "test_helper"

# Schema.violations and Schema.strict: the client-side halves of structured
# output — validation everywhere, wire preparation for constrained decoding.
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
    assert_includes errors, "$.tiers[0].label must be one of: basic, pro"
    assert_includes errors, "$.count must be integer, got string"
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
    refute_empty Mistri::Schema.violations(
      { "count" => 3.5 },
      { type: "object", properties: { "count" => { type: "integer" } } }
    )
  end

  def test_additional_properties_false_rejects_strays
    schema = { type: "object", properties: { "a" => { type: "string" } },
               additionalProperties: false }

    assert_equal ["$.b is not allowed"], Mistri::Schema.violations({ "a" => "x", "b" => 1 }, schema)
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
end
