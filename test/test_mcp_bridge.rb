# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_stub_server"

# The bridge: MCP tools become Mistri tools, results become model-readable
# content, and the harness's own features compose on top.
class TestMcpBridge < Minitest::Test
  def test_tools_map_with_prefix_filters_and_gates
    listed = [{ "name" => "create", "description" => "Creates.",
                "inputSchema" => { "type" => "object",
                                   "properties" => { "title" => { "type" => "string" } } } },
              { "name" => "search", "description" => "Searches." },
              { "name" => "purge", "description" => "Purges." }]
    client = Struct.new(:tools).new(listed)

    tools = Mistri::MCP.tools(client, deny: ["purge"], prefix: "linear",
                                      gates: { "create" => true })

    assert_equal %w[linear__create linear__search], tools.map(&:name)
    assert tools.first.needs_approval?({})
    refute tools.last.needs_approval?({})
    assert_equal({ "type" => "object", "properties" => { "title" => { "type" => "string" } } },
                 tools.first.spec[:input_schema])
  end

  def test_answers_map_text_errors_images_and_structured_content
    text = { "content" => [{ "type" => "text", "text" => "found 3" },
                           { "type" => "text", "text" => "more" }] }

    assert_equal "found 3\nmore", Mistri::MCP.answer(text)

    failed = { "isError" => true, "content" => [{ "type" => "text", "text" => "no access" }] }

    assert_equal "MCP tool error: no access", Mistri::MCP.answer(failed)

    image = { "content" => [{ "type" => "image", "data" => ["png!"].pack("m0"),
                              "mimeType" => "image/png" }] }
    blocks = Mistri::MCP.answer(image)

    assert_instance_of Mistri::Content::Image, blocks.first

    structured = { "content" => [], "structuredContent" => { "count" => 3 } }

    assert_equal '{"count":3}', Mistri::MCP.answer(structured)
  end

  def test_an_agent_uses_a_bridged_tool_end_to_end
    tools = { "lookup" => { description: "Looks up facts.",
                            handler: ->(args) { "fact: #{args["q"]} is 42" } } }
    server = Mistri::Test::McpStubServer.new(tools: tools, session: "s")
    client = Mistri::MCP::Client.new(url: server.url)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "kb__lookup",
                                                              arguments: { "q" => "answer" } }] },
                                             { text: "It is 42." }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: Mistri::MCP.tools(client, prefix: "kb"))

    result = agent.run("what is the answer?")

    assert_predicate result, :completed?
    assert_equal "fact: answer is 42", agent.session.messages.select(&:tool?).last.text
    assert_equal "lookup", server.calls.first["name"], "the remote name, not the prefixed one"
  ensure
    server.stop
  end

  def test_an_ambiguous_delivery_warns_the_model_not_to_retry
    tools = { "send" => { description: "Sends once.", handler: ->(_) { "sent" } } }
    server = Mistri::Test::McpStubServer.new(tools: tools, drop_after: "tools/call")
    client = Mistri::MCP::Client.new(url: server.url)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send", arguments: {} }] },
                                             { text: "I will verify before retrying." }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: Mistri::MCP.tools(client))

    agent.run("send it")

    result = agent.session.messages.find(&:tool?)

    assert_match(/AmbiguousDeliveryError/, result.text)
    assert_match(/do not retry automatically/, result.text)
    assert_equal 1, server.calls.length
  ensure
    server&.stop
  end

  def test_an_approval_gate_parks_a_bridged_tool_before_the_server_sees_it
    tools = { "send" => { description: "Sends.", handler: ->(_) { "sent" } } }
    server = Mistri::Test::McpStubServer.new(tools: tools)
    client = Mistri::MCP::Client.new(url: server.url)
    bridged = Mistri::MCP.tools(client, gates: { "send" => true })
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send", arguments: {} }] }
                                           ])

    result = Mistri::Agent.new(provider:, tools: bridged).run("send it")

    assert_predicate result, :awaiting_approval?
    assert_empty server.calls, "the third-party tool never ran without a human"
  ensure
    server.stop
  end
end
