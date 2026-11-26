# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"

# The parameters a 2026-07-28 server marks to be repeated as HTTP headers.
class TestMcpMirror < Minitest::Test
  MIRROR = Mistri::MCP.const_get(:Mirror)
  NEWEST = { "supportedVersions" => ["2026-07-28"] }.freeze

  def schema(properties) = { "type" => "object", "properties" => properties }

  def marked(name, type = "string") = { "type" => type, "x-mcp-header" => name }

  def test_marks_that_follow_the_rules_have_no_violation
    nested = schema("where" => schema("region" => marked("Region")),
                    "count" => marked("Count", "integer"),
                    "x-mcp-header" => { "type" => "string" })

    assert_nil MIRROR.violation(nested)
    assert_nil MIRROR.violation(schema("plain" => { "type" => "string" }))
    assert_nil MIRROR.violation(nil)
  end

  def test_each_broken_rule_is_named
    cases = {
      /not a header name/ => [schema("a" => marked("")), schema("a" => marked("two words")),
                              schema("a" => marked("colon:name")), schema("a" => marked(7)),
                              schema("a" => marked("caf\u00e9"))],
      /names one header twice/ => [schema("a" => marked("Region"), "b" => marked("region"))],
      /not a string, an integer or a boolean/ => [schema("a" => marked("N", "number")),
                                                  schema("a" => marked("N", "object")),
                                                  schema("a" => marked("N", %w[string null]))],
      /property names alone do not reach/ => [
        schema("list" => { "type" => "array", "items" => marked("Item") }),
        { "anyOf" => [schema("a" => marked("Either"))] }
      ]
    }

    cases.each do |reason, schemas|
      schemas.each { |broken| assert_match reason, MIRROR.violation(broken), broken.inspect }
    end
  end

  def test_a_marked_parameter_becomes_a_header_and_an_absent_one_none
    marks = schema("region" => marked("Region"), "count" => marked("Count", "integer"),
                   "dry" => marked("Dry", "boolean"), "empty" => marked("Empty"),
                   "gone" => marked("Gone"), "null" => marked("Null"), "odd" => marked("Odd"),
                   "where" => schema("zone" => marked("Zone")), "query" => { "type" => "string" })
    arguments = { region: "us-west1", "count" => 42, "dry" => false, "empty" => "", "null" => nil,
                  "odd" => [1], "where" => { "zone" => "b" }, "query" => "SELECT 1" }

    assert_equal({ "Mcp-Param-Region" => "us-west1", "Mcp-Param-Count" => "42",
                   "Mcp-Param-Dry" => "false", "Mcp-Param-Empty" => "", "Mcp-Param-Zone" => "b" },
                 MIRROR.headers(marks, arguments))
    assert_empty MIRROR.headers(marks, nil)
    assert_empty MIRROR.headers(schema("region" => marked("Region")),
                                { "region" => { "zone" => "b" } })
    assert_empty MIRROR.headers(schema("query" => { "type" => "string" }), arguments)
  end

  def test_a_value_that_is_not_plain_is_sent_as_base64
    plain = ["us-west1", "", "two words", "~"]
    encoded = { "Hello, \u4e16\u754c" => "=?base64?SGVsbG8sIOS4lueVjA==?=",
                " padded " => "=?base64?IHBhZGRlZCA=?=",
                "line1\nline2" => "=?base64?bGluZTEKbGluZTI=?=", "\ttab" => "=?base64?CXRhYg==?=",
                "=?base64?literal?=" => "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=" }

    plain.each { |text| assert_equal text, MIRROR.value(text) }
    encoded.each { |text, sent| assert_equal sent, MIRROR.value(text), text.inspect }
  end

  def test_a_call_carries_its_marked_parameters_and_a_broken_tool_is_left_out
    listed = [{ "name" => "query", "inputSchema" => schema("region" => marked("Region"),
                                                           "sql" => { "type" => "string" }) },
              { "name" => "broken", "inputSchema" => schema("a" => marked("N", "number")) }, 7]
    echo = ->(server, socket, id) { server.result(socket, id, server.answer(id, "ok")["result"]) }
    server = Mistri::Test::McpScriptedServer.new(tools: { "query" => echo, "caf\u00e9" => echo },
                                                 discover: NEWEST, listed: listed)
    client = Mistri::MCP::Client.new(url: server.url, allow_non_public: Mistri::Test::ALLOW_LOOPBACK)

    _out, warned = capture_io do
      client.call_tool("query", { "region" => "eu-1", "sql" => "SELECT 1" })
    end
    client.call_tool("caf\u00e9", {})
    sent = server.requests("POST").map { |request| request[:headers] }

    assert_equal [listed.first, 7], client.tools, "an entry that is no tool is left for the bridge"
    assert_match(/the MCP tool "broken" was left out: x-mcp-header is on a parameter that is not/,
                 warned)
    assert_equal(%w[server/discover tools/list tools/call tools/call], server.posted.map do |m|
      m["method"]
    end)
    assert_equal %w[eu-1 query], sent[2].values_at("mcp-param-region", "mcp-name")
    assert_nil sent[2]["mcp-param-sql"]
    assert_equal "=?base64?Y2Fmw6k=?=", sent[3]["mcp-name"]
  ensure
    client&.close
    server&.stop
  end
end
