# frozen_string_literal: true

require_relative "test_helper"

# An MCP server may declare its tool schemas in draft-07, which is what common
# schema generators emit. It reads the same as 2020-12 for everything Mistri
# validates, apart from two shapes that are refused for that one tool.
class TestMcpDraft7Schema < Minitest::Test
  DRAFT7 = "http://json-schema.org/draft-07/schema#"

  def bridge(schema)
    definition = { "name" => "search", "description" => "Searches.", "inputSchema" => schema }
    Mistri::MCP.bridge(Struct.new(:tools).new([definition]), definition)
  end

  def draft7(**keywords) = { "$schema" => DRAFT7, "type" => "object" }.merge(keywords)

  def test_a_draft7_schema_is_bridged_and_its_arguments_are_validated
    tool = bridge(draft7("properties" => { "query" => { "type" => "string" } },
                         "required" => ["query"], "additionalProperties" => false))

    assert_equal DRAFT7, tool.input_schema["$schema"]
    assert_empty tool.argument_violations("query" => "whisper")
    assert_equal ["$.query is required"], tool.argument_violations({})
    assert_equal ["$.query must be string, got integer"], tool.argument_violations("query" => 7)
  end

  def test_the_address_without_its_fragment_is_the_same_format
    tool = bridge("$schema" => DRAFT7.delete_suffix("#"), "type" => "object")

    assert_empty tool.argument_violations({})
  end

  def test_the_keywords_draft7_names_differently_are_read
    tool = bridge(draft7(
                    "properties" => { "card" => { "$ref" => "#/definitions/card" } },
                    "definitions" => { "card" => { "type" => "string" } },
                    "dependencies" => { "card" => ["billing"] }
                  ))

    assert_empty tool.argument_violations("card" => "4242", "billing" => "x")
  end

  def test_items_as_an_array_means_something_else_in_draft7_and_is_refused
    pair = { "type" => "array", "items" => [{ "type" => "string" }] }
    error = assert_raises(Mistri::ConfigurationError) do
      bridge(draft7("properties" => { "pair" => pair }))
    end

    assert_match(/MCP tool "search": \$\.properties\.pair\.items/, error.message)
  end

  def test_a_constraint_beside_a_reference_is_ignored_by_draft7_and_is_refused
    reference = { "$ref" => "#/definitions/card", "type" => "integer" }
    error = assert_raises(Mistri::ConfigurationError) do
      bridge(draft7("properties" => { "card" => reference },
                    "definitions" => { "card" => { "type" => "string" } }))
    end

    assert_match(/MCP tool "search": \$\.properties\.card\.type/, error.message)
    assert_match(/draft-07/, error.message)
  end

  def test_every_keyword_that_is_validated_locally_is_refused_beside_a_reference
    beside = { "type" => "object", "enum" => [{}], "required" => ["a"],
               "properties" => { "a" => {} }, "additionalProperties" => false,
               "items" => { "type" => "string" } }

    beside.each do |keyword, value|
      reference = { "$ref" => "#/definitions/card", keyword => value }
      error = assert_raises(Mistri::ConfigurationError, keyword) do
        bridge(draft7("properties" => { "card" => reference },
                      "definitions" => { "card" => {} }))
      end

      assert_match(/\$\.properties\.card\.#{keyword} is ignored beside \$ref/, error.message)
    end
  end

  def test_a_description_beside_a_reference_is_fine
    reference = { "$ref" => "#/definitions/card", "description" => "The card." }
    tool = bridge(draft7("properties" => { "card" => reference },
                         "definitions" => { "card" => { "type" => "string" } }))

    assert_empty tool.argument_violations("card" => "4242")
  end

  def test_a_constraint_beside_a_reference_is_kept_in_the_newer_format
    reference = { "$ref" => "#/$defs/card", "type" => "string" }
    tool = bridge("$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object",
                  "properties" => { "card" => reference },
                  "$defs" => { "card" => { "type" => "string" } })

    assert_equal ["$.card must be string, got integer"], tool.argument_violations("card" => 7)
  end

  def test_any_other_format_is_still_refused
    ["http://json-schema.org/draft-04/schema#",
     "https://json-schema.org/draft/2019-09/schema"].each do |dialect|
      error = assert_raises(Mistri::ConfigurationError) do
        bridge("$schema" => dialect, "type" => "object")
      end

      assert_match(/\$\.\$schema must declare JSON Schema 2020-12 or draft-07/, error.message)
    end
  end

  def test_a_keyword_draft7_does_not_have_is_refused
    pair = { "type" => "array", "prefixItems" => [{ "type" => "string" }] }
    error = assert_raises(Mistri::ConfigurationError) do
      bridge(draft7("properties" => { "pair" => pair }))
    end

    assert_match(/\$\.properties\.pair\.prefixItems is not a draft-07 keyword/, error.message)
  end

  def test_a_tool_the_host_writes_may_declare_draft7_too
    tool = Mistri::Tool.define("search", "Searches.",
                               input_schema: draft7("required" => ["query"])) { "ok" }

    assert_equal ["$.query is required"], tool.argument_violations({})
  end
end
