# frozen_string_literal: true

require_relative "test_helper"

# The adapter for the official MCP Ruby SDK's client. Mistri does not depend
# on the SDK, so the stand-in here answers as its client does: tools as
# objects, call_tool with keywords and the whole JSON-RPC response.
class TestMcpSdkClient < Minitest::Test
  Listed = Struct.new(:name, :title, :description, :input_schema, :annotations, keyword_init: true)

  class Stand
    attr_reader :calls, :instructions

    def initialize(capabilities: nil, instructions: nil, response: :answer)
      @capabilities = capabilities
      @instructions = instructions
      @response = response
      @calls = []
    end

    def tools
      [Listed.new(name: "lookup", title: "Look up", description: "Looks a word up.",
                  input_schema: { "type" => "object",
                                  "properties" => { "q" => { "type" => "string" } } },
                  annotations: { "readOnlyHint" => true }),
       Listed.new(name: "bare")]
    end

    def call_tool(name:, arguments:)
      @calls << [name, arguments]
      return @response unless @response == :answer

      { "jsonrpc" => "2.0", "id" => "7",
        "result" => { "content" => [{ "type" => "text", "text" => "found #{arguments["q"]}" }] } }
    end

    def server_capabilities = @capabilities

    def read_resource(uri:) = [{ "uri" => uri, "text" => "the notes" }]
  end

  def test_the_sdks_client_bridges_through_the_adapter
    stand = Stand.new
    lookup, bare = Mistri::MCP.tools(Mistri::MCP::SDKClient.new(stand), prefix: "kb")

    assert_equal %w[kb__lookup kb__bare], [lookup.name, bare.name]
    assert_equal "Looks a word up.", lookup.description
    assert_predicate lookup, :parallel?
    refute_predicate bare, :parallel?
    assert_equal "found plums", lookup.call({ "q" => "plums" })
    assert_equal [["lookup", { "q" => "plums" }]], stand.calls
  end

  def test_a_tool_is_listed_as_the_hash_the_bridge_takes
    listed = Mistri::MCP::SDKClient.new(Stand.new).tools

    assert_equal({ "name" => "lookup", "title" => "Look up", "description" => "Looks a word up.",
                   "inputSchema" => { "type" => "object",
                                      "properties" => { "q" => { "type" => "string" } } },
                   "annotations" => { "readOnlyHint" => true } }, listed.first)
    assert_equal({ "name" => "bare" }, listed.last)
  end

  def test_a_response_with_no_result_is_an_error
    [nil, "text", {}, { "result" => "text" }].each do |response|
      client = Mistri::MCP::SDKClient.new(Stand.new(response: response))
      error = assert_raises(Mistri::MCP::Error) { client.call_tool("lookup", {}) }

      assert_equal "tools/call returned a malformed result", error.message
    end
  end

  def test_instructions_and_resources_reach_the_bridge
    told = Stand.new(instructions: "Look a word up before you spell it.",
                     capabilities: { "resources" => {} })
    client = Mistri::MCP::SDKClient.new(told)
    tools = Mistri::MCP.tools(client, prefix: "kb")

    assert_equal "Look a word up before you spell it.", client.instructions
    assert_predicate client, :resources?
    assert_equal "kb__read_resource", tools.last.name
    assert_equal "the notes", tools.last.call({ "uri" => "notes://today" })
  end

  def test_a_server_that_declares_no_resources_gets_no_tool_for_them
    [nil, {}, { "tools" => {} }].each do |capabilities|
      client = Mistri::MCP::SDKClient.new(Stand.new(capabilities: capabilities))

      refute_predicate client, :resources?
      assert_equal %w[lookup bare], Mistri::MCP.tools(client).map(&:name)
    end
  end
end
