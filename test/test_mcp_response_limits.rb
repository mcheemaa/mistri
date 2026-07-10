# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_stub_server"

# Response overflow keeps JSON-RPC confirmation and replay semantics honest.
class TestMcpResponseLimits < Minitest::Test
  ECHO = { "echo" => { description: "Echoes.", handler: lambda { |args|
    "echo: #{args["text"]}"
  } } }.freeze

  def test_an_oversized_tool_response_is_ambiguous_over_json_and_sse
    tools = { "large" => { description: "Large.", handler: ->(_) { "x" * 2000 } } }

    [true, false].each do |sse|
      with_server(tools: tools, sse: sse, session: "sess") do |server|
        client = remote_client(server, max_record_bytes: 512)

        error = assert_raises(Mistri::AmbiguousDeliveryError) do
          client.call_tool("large", {})
        end

        assert_match(/may have completed/, error.message)
        assert_match(/do not retry automatically/, error.message)
        assert_instance_of Mistri::ResponseTooLargeError, error.cause
        assert_equal(sse ? :sse_line : :json_body, error.cause.kind)
        assert_equal 1, server.calls.length

        client.connect
        initialize_requests = requests_for(server, "initialize")

        assert_equal 2, server.initializes, "the next operation performs a fresh handshake"
        assert_nil initialize_requests.last[:headers]["mcp-session-id"]
        assert_nil initialize_requests.last[:headers]["mcp-protocol-version"]
      end
    end
  end

  def test_an_oversized_replayable_response_fails_without_replay
    tools = { "large" => { description: "x" * 2000, handler: ->(_) { "unused" } } }
    with_server(tools: tools) do |server|
      client = remote_client(server, max_record_bytes: 512)

      error = assert_raises(Mistri::ResponseTooLargeError) { client.tools }

      assert_equal :sse_line, error.kind
      assert_equal 1, requests_for(server, "tools/list").length
      assert_empty server.calls
    end
  end

  def test_a_confirmed_tool_result_survives_an_oversized_trailing_sse_line
    with_server(trailing_after: "tools/call") do |server|
      client = remote_client(server, max_record_bytes: 512)

      result = client.call_tool("echo", { "text" => "confirmed" })

      assert_equal "echo: confirmed", result.dig("content", 0, "text")
      assert_equal 1, server.calls.length

      client.connect

      assert_equal 2, server.initializes, "the malformed stream forced a clean handshake"
    end
  end

  def test_an_initialize_with_trailing_overflow_is_restarted_cleanly
    with_server(trailing_after: "initialize", session: "sess") do |server|
      client = remote_client(server, max_record_bytes: 512)

      assert_raises(Mistri::ResponseTooLargeError) { client.connect }
      client.connect

      methods = server.bodies.map { |body| body["method"] }

      assert_equal %w[initialize initialize notifications/initialized], methods
      assert_nil requests_for(server, "initialize").last[:headers]["mcp-session-id"]
      assert_nil requests_for(server, "initialize").last[:headers]["mcp-protocol-version"]
    end
  end

  private

  def with_server(tools: ECHO, **)
    server = Mistri::Test::McpStubServer.new(tools: tools, **)
    yield server
  ensure
    server&.stop
  end

  def remote_client(server, **)
    Mistri::MCP::Client.new(url: server.url,
                            allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **)
  end

  def requests_for(server, method)
    server.requests.select { |request| JSON.parse(request[:body])["method"] == method }
  end
end
