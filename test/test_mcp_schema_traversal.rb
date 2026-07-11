# frozen_string_literal: true

require_relative "test_helper"

# Remote schema guidance remains structurally bounded: nested contracts cannot
# hide references or key-matching semantics from the bridge's safety checks.
class TestMcpSchemaTraversal < Minitest::Test
  def test_legacy_dependencies_shapes_are_validated
    invalid = [
      [[], /dependencies must be an object/],
      [{ "kind" => %w[name name] }, /dependencies\.kind must be a schema or array/],
      [{ "kind" => 7 }, /dependencies\.kind must be a schema object or boolean/]
    ]

    invalid.each do |dependencies, message|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::MCP.tools(client_for("dependencies" => dependencies))
      end

      assert_match message, error.message
    end

    assert Mistri::MCP.tools(client_for("dependencies" => { "kind" => [] })).first
  end

  def test_external_references_nested_under_legacy_dependencies_are_rejected
    %w[$ref $dynamicRef].each do |keyword|
      schema = { "dependencies" => {
        "kind" => { keyword => "https://example.com/remote-schema" }
      } }

      path = /\$\.dependencies\.kind\.#{Regexp.escape(keyword)}/

      assert_external_reference_rejected(schema, path)
    end
  end

  def test_external_references_nested_under_content_schema_are_rejected
    %w[$ref $dynamicRef].each do |keyword|
      schema = { "properties" => {
        "payload" => {
          "type" => "string",
          "contentSchema" => { keyword => "https://example.com/remote-schema" }
        }
      } }

      path = /\$\.properties\.payload\.contentSchema\.#{Regexp.escape(keyword)}/

      assert_external_reference_rejected(schema, path)
    end
  end

  def test_schema_dependencies_are_guidance_but_pattern_matching_needs_authority
    schema = {
      "$defs" => { "named" => { "type" => "string" } },
      "dependencies" => {
        "kind" => { "$ref" => "#/$defs/named" },
        "labels" => {
          "patternProperties" => { "^x-" => { "type" => "string" } }
        }
      }
    }
    client = client_for(schema)

    error = assert_raises(Mistri::ConfigurationError) { Mistri::MCP.tools(client) }

    assert_match(/dependencies\.labels\.patternProperties/, error.message)
    assert Mistri::MCP.tools(client, complete_argument_validator: ->(*) { [] }).first
  end

  private

  def client_for(schema)
    schema = { "type" => "object" }.merge(schema)
    Struct.new(:tools).new(
      [{ "name" => "remote", "description" => "Remote.", "inputSchema" => schema }]
    )
  end

  def assert_external_reference_rejected(schema, path)
    [nil, ->(*) { [] }].each do |validator|
      options = validator ? { complete_argument_validator: validator } : {}
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::MCP.tools(client_for(schema), **options)
      end

      assert_match path, error.message
      assert_match(/same-document reference beginning with #/, error.message)
    end
  end
end
