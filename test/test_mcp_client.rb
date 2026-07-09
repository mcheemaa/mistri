# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_stub_server"

# The MCP client against a real socket: handshake, pagination, sessions,
# auth refresh, and the spec's session-expiry recovery.
class TestMcpClient < Minitest::Test
  ECHO = { "echo" => { description: "Echoes.", handler: lambda { |args|
    "echo: #{args["text"]}"
  } } }.freeze

  def with_server(**)
    server = Mistri::Test::McpStubServer.new(tools: ECHO, **)
    yield server
  ensure
    server.stop
  end

  def test_the_handshake_negotiates_and_announces
    with_server(session: "sess") do |server|
      client = Mistri::MCP::Client.new(url: server.url)
      client.connect

      assert_equal "stub", client.server_info["name"]

      methods = server.bodies.map { |b| b["method"] }

      assert_equal %w[initialize notifications/initialized], methods

      init = server.bodies.first["params"]

      assert_equal "2025-11-25", init["protocolVersion"]
      assert_equal "mistri", init.dig("clientInfo", "name")

      client.call_tool("echo", { "text" => "hi" })

      last = server.requests.last[:headers]

      assert_equal "sess-1", last["mcp-session-id"], "the session rides every request"
      assert_equal "2025-11-25", last["mcp-protocol-version"]
    end
  end

  def test_tools_list_merges_pages_and_caches
    tools = { "a" => { description: "A.", handler: ->(_) { "a" } },
              "b" => { description: "B.", handler: ->(_) { "b" } },
              "c" => { description: "C.", handler: ->(_) { "c" } } }
    with_server(tools: tools, page_size: 2) do |server|
      client = Mistri::MCP::Client.new(url: server.url)

      assert_equal(%w[a b c], client.tools.map { |t| t["name"] })

      client.tools

      list_calls = server.bodies.count { |b| b["method"] == "tools/list" }

      assert_equal 2, list_calls, "two pages, then the cache answers"
    end
  end

  def test_plain_json_servers_work_identically
    with_server(sse: false) do |server|
      client = Mistri::MCP::Client.new(url: server.url)
      result = client.call_tool("echo", { "text" => "json mode" })

      assert_equal "echo: json mode", result.dig("content", 0, "text")
    end
  end

  def test_a_token_lambda_refreshes_once_on_unauthorized
    with_server(require_token: "fresh") do |server|
      handed = %w[stale fresh]
      resolved = []
      token = lambda do
        value = handed.length > 1 ? handed.shift : handed.first
        resolved << value
        value
      end
      client = Mistri::MCP::Client.new(url: server.url, token: token)
      result = client.call_tool("echo", { "text" => "hi" })

      assert_equal "echo: hi", result.dig("content", 0, "text")
      assert_equal "stale", resolved.first, "the first attempt used the stale token"
      assert_includes resolved, "fresh"
    end
  end

  def test_a_static_token_401_raises
    with_server(require_token: "right") do |server|
      client = Mistri::MCP::Client.new(url: server.url, token: "wrong")

      assert_raises(Mistri::AuthenticationError) { client.call_tool("echo", {}) }
    end
  end

  def test_an_expired_session_reinitializes_transparently
    with_server(session: "sess", expire_after: 3) do |server|
      client = Mistri::MCP::Client.new(url: server.url)
      client.call_tool("echo", { "text" => "one" })
      result = client.call_tool("echo", { "text" => "two" })

      assert_equal "echo: two", result.dig("content", 0, "text")
      assert_equal 2, server.initializes, "the client started a fresh session"
    end
  end

  def test_a_dropped_tool_response_does_not_replay_the_call
    with_server(drop_after: "tools/call") do |server|
      client = Mistri::MCP::Client.new(url: server.url)

      error = assert_raises(Mistri::AmbiguousDeliveryError) do
        client.call_tool("echo", { "text" => "once" })
      end

      assert_match(/may have completed/, error.message)
      assert_match(/do not retry automatically/, error.message)
      assert_equal 1, server.calls.length
    end
  end

  def test_a_dropped_replayable_request_reconnects_once
    with_server(drop_after: "tools/list") do |server|
      client = Mistri::MCP::Client.new(url: server.url)
      names = client.tools.map { |tool| tool["name"] }
      list_calls = server.bodies.count { |body| body["method"] == "tools/list" }

      assert_equal ["echo"], names
      assert_equal 2, list_calls
    end
  end

  def test_a_malformed_tool_response_is_ambiguous
    with_server(malformed_after: "tools/call") do |server|
      client = Mistri::MCP::Client.new(url: server.url)

      error = assert_raises(Mistri::AmbiguousDeliveryError) do
        client.call_tool("echo", { "text" => "once" })
      end

      assert_match(/may have completed/, error.message)
      assert_equal 1, server.calls.length
    end
  end

  def test_a_malformed_replayable_response_is_not_replayed
    with_server(malformed_after: "tools/list") do |server|
      client = Mistri::MCP::Client.new(url: server.url)

      assert_raises(Mistri::ProviderError) { client.tools }
      list_calls = server.bodies.count { |body| body["method"] == "tools/list" }

      assert_equal 1, list_calls
      assert_empty server.calls
    end
  end

  def test_a_missing_tool_response_is_ambiguous
    with_server(empty_after: "tools/call") do |server|
      client = Mistri::MCP::Client.new(url: server.url)

      error = assert_raises(Mistri::AmbiguousDeliveryError) do
        client.call_tool("echo", { "text" => "once" })
      end

      assert_match(/no matching response/, error.message)
      assert_equal 1, server.calls.length
    end
  end

  def test_a_missing_replayable_response_remains_a_protocol_error
    with_server(empty_after: "tools/list") do |server|
      client = Mistri::MCP::Client.new(url: server.url)

      error = assert_raises(Mistri::MCP::Error) { client.tools }

      assert_match(/no matching response/, error.message)
      assert_empty server.calls
    end
  end

  def test_an_unsupported_protocol_version_fails_loudly
    with_server(protocol: "1999-01-01") do |server|
      client = Mistri::MCP::Client.new(url: server.url)
      error = assert_raises(Mistri::MCP::Error) { client.connect }

      assert_match(/unsupported protocol version/, error.message)
    end
  end

  def test_a_bearer_token_over_plain_http_to_a_remote_host_is_refused
    assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP::Client.new(url: "http://mcp.example.com/mcp", token: "secret")
    end
  end
end
