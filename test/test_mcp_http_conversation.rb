# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/stub_server"
require "timeout"

# What a Streamable HTTP server does besides answer: it asks on the stream of
# a call, drops the stream after the answer, or takes too long.
class TestMcpHttpConversation < Minitest::Test
  def setup
    @server = Mistri::Test::StubServer.new { |socket, request| serve(socket, request) }
    @client = Mistri::MCP::Client.new(url: "#{@server.origin}/mcp",
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
  end

  def teardown
    @client.close
    @server.stop
  end

  def test_a_request_with_the_id_of_the_call_is_not_its_answer
    result = @client.call_tool("asks", {})

    assert_equal "asked", result.dig("content", 0, "text")
    assert_empty posted.select { |message| message.key?("result") },
                 "the one connection is taken while the stream is read"
  end

  def test_an_answer_stands_when_the_stream_drops_after_it
    result = @client.call_tool("drops", {})

    assert_equal "dropped", result.dig("content", 0, "text")
  end

  def test_a_caller_that_stops_waiting_cancels_the_call
    @client.connect

    assert_raises(Timeout::Error) { Timeout.timeout(0.2) { @client.call_tool("slow", {}) } }
    result = @client.call_tool("echo", {})

    assert_equal "echo", result.dig("content", 0, "text")
    assert_includes posted, { "jsonrpc" => "2.0", "method" => "notifications/cancelled",
                              "params" => { "requestId" => 2,
                                            "reason" => "the caller stopped waiting" } }
  end

  private

  def posted = @server.requests.map { |request| JSON.parse(request[:body]) }

  def serve(socket, request)
    message = JSON.parse(request[:body])
    id = message["id"]
    return @server.respond_json(socket, "", status: 202) unless id && message["method"]
    return @server.respond_json(socket, answer(id, handshake)) if message["method"] == "initialize"

    name = message.dig("params", "name")
    sleep 0.5 if name == "slow"
    @server.start_sse(socket)
    ask = { "jsonrpc" => "2.0", "id" => id, "method" => "ping" }
    @server.sse_data(socket, ask) if name == "asks"
    said = { "content" => [{ "type" => "text", "text" => TEXT[name] }] }
    @server.sse_data(socket, answer(id, said))
    return :close if name == "drops"

    @server.finish_sse(socket)
  end

  TEXT = { "asks" => "asked", "drops" => "dropped", "slow" => "slow", "echo" => "echo" }.freeze
  private_constant :TEXT

  def answer(id, result) = { "jsonrpc" => "2.0", "id" => id, "result" => result }

  def handshake
    { "protocolVersion" => "2025-11-25", "capabilities" => {},
      "serverInfo" => { "name" => "stub", "version" => "1" } }
  end
end
