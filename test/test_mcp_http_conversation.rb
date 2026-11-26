# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"
require "timeout"

# What a Streamable HTTP server does besides answer: it asks on the stream of
# a call, goes silent, drops the stream, refuses, and is told when the client
# is done.
class TestMcpHttpConversation < Minitest::Test
  ECHO = lambda do |server, socket, id|
    server.open(socket)
    server.event(socket, server.answer(id, "echo"))
    server.finish(socket)
  end
  ASKS = lambda do |server, socket, id|
    server.open(socket)
    server.event(socket, { "jsonrpc" => "2.0", "id" => "srv-1", "method" => "ping" })
    server.event(socket, { "jsonrpc" => "2.0", "id" => id, "method" => "sampling/createMessage" })
    replies = Array.new(2) { server.reply }
    server.event(socket, server.answer(id, JSON.generate(replies)))
    server.finish(socket)
  end
  DROPS = lambda do |server, socket, id|
    server.open(socket)
    server.event(socket, server.answer(id, "dropped"))
    :close
  end
  CUT = lambda do |server, socket, _id|
    server.open(socket)
    server.raw(socket, 'data: {"jsonrpc":"2.0","id":')
    :close
  end
  SLOW = lambda do |server, socket, id|
    sleep 0.5
    ECHO.call(server, socket, id)
  end
  COMMENTS = lambda do |server, socket, _id|
    server.open(socket)
    60.times do
      server.raw(socket, ": still here\n\n")
      sleep 0.03
    end
    :close
  end
  FLOODS = lambda do |server, socket, _id|
    server.open(socket)
    stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    server.raw(socket, ": again\n\n") while Process.clock_gettime(Process::CLOCK_MONOTONIC) < stop
    :close
  end
  REFUSED = lambda do |server, socket, id|
    server.json(socket, { "jsonrpc" => "2.0", "id" => id,
                          "error" => { "code" => -32_602, "message" => "Bad arguments" } },
                status: 400)
  end
  BROKEN = ->(server, socket, _id) { server.json(socket, "upstream is down", status: 502) }
  TOOLS = { "echo" => ECHO, "asks" => ASKS, "drops" => DROPS, "cut" => CUT, "slow" => SLOW,
            "comments" => COMMENTS, "floods" => FLOODS, "refused" => REFUSED,
            "broken" => BROKEN }.freeze

  def teardown
    @client&.close
    @server&.stop
  end

  def test_a_request_from_the_server_is_answered_while_the_stream_is_read
    result = client.call_tool("asks", {})

    assert_equal [{ "jsonrpc" => "2.0", "id" => "srv-1", "result" => {} },
                  { "jsonrpc" => "2.0", "id" => @server.calling,
                    "error" => { "code" => -32_601, "message" => "Method not found" } }],
                 JSON.parse(result.dig("content", 0, "text")),
                 "a request with the id of the call was not taken for its answer"
  end

  def test_an_answer_stands_when_the_stream_drops_after_it
    result = client.call_tool("drops", {})

    assert_equal "dropped", result.dig("content", 0, "text")
  end

  def test_a_dropped_stream_fails_the_call_and_keeps_the_session
    error = assert_raises(Mistri::AmbiguousDeliveryError) { client.call_tool("cut", {}) }
    @client.call_tool("echo", {})

    assert_match(/may have completed/, error.message)
    assert_equal 1, @server.sent("initialize").length
    assert_equal "s1", @server.requests("POST").last[:headers]["mcp-session-id"]
  end

  def test_a_caller_that_stops_waiting_cancels_the_call
    client.connect

    assert_raises(Timeout::Error) { Timeout.timeout(0.2) { @client.call_tool("slow", {}) } }
    result = @client.call_tool("echo", {})

    stopped = { "requestId" => called("tools/call"), "reason" => "the caller stopped waiting" }

    assert_equal "echo", result.dig("content", 0, "text")
    assert_equal [stopped], cancels
  end

  def test_comments_do_not_move_the_wait_for_a_message
    client(read_timeout: 0.3).connect
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Mistri::AmbiguousDeliveryError) { @client.call_tool("comments", {}) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    @client.call_tool("echo", {})

    assert_match(/timed out waiting for the MCP server/, error.message)
    assert_in_delta 0.3, elapsed, 0.2
    assert_equal [{ "requestId" => called("tools/call"), "reason" => "timed out" }], cancels
    assert_equal 1, @server.sent("initialize").length, "the session is kept"
  end

  def test_a_stream_of_comments_with_no_pause_ends_at_the_read_timeout
    client(read_timeout: 0.3).connect
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Mistri::AmbiguousDeliveryError) { @client.call_tool("floods", {}) }

    assert_match(/timed out waiting for the MCP server/, error.message)
    assert_in_delta 0.3, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, 0.25
  end

  def test_a_list_that_times_out_is_cancelled_and_keeps_the_session
    client(read_timeout: 0.3).connect
    @server.list_wait = 1

    error = assert_raises(Mistri::MCP::Error) { @client.tools }
    @server.list_wait = 0

    assert_match(/timed out waiting for the MCP server/, error.message)
    assert_empty @client.tools
    assert_equal([called("tools/list")], cancels.map { |params| params["requestId"] })
    assert_equal 1, @server.sent("initialize").length
  end

  def test_a_refusal_names_the_mcp_server_and_what_it_said
    error = assert_raises(Mistri::ProviderError) { client.call_tool("refused", {}) }

    assert_equal "the MCP server answered HTTP 400: Bad arguments", error.message
    assert_equal 400, error.status
    assert_includes error.body, "Bad arguments"
  end

  def test_a_refusal_with_no_message_keeps_its_class
    error = assert_raises(Mistri::ServerError) { client.call_tool("broken", {}) }

    assert_equal "the MCP server answered HTTP 502", error.message
    assert_equal "upstream is down", error.body
  end

  def test_close_ends_the_session_with_the_token_last_sent
    asked = 0
    token = lambda do
      asked += 1
      "token-#{asked}"
    end
    client(token: token).connect
    before = asked
    @client.close
    ended = @server.requests("DELETE")

    assert_equal 1, ended.length
    assert_equal "s1", ended.first[:headers]["mcp-session-id"]
    assert_equal "Bearer token-#{before}", ended.first[:headers]["authorization"]
    assert_equal before, asked, "a close does not ask for a token"
  end

  def test_close_stands_when_the_server_refuses_to_end_the_session
    client(delete_status: 500).connect

    assert_nil @client.close
    assert_equal 1, @server.requests("DELETE").length
  end

  def test_close_sends_nothing_when_there_is_no_session
    client(session: nil).connect
    @client.close

    assert_empty @server.requests("DELETE")
  end

  private

  def client(read_timeout: 10, token: nil, **)
    @server = Mistri::Test::McpScriptedServer.new(tools: TOOLS, **)
    @client = Mistri::MCP::Client.new(url: @server.url, read_timeout: read_timeout, token: token,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
  end

  def cancels = @server.sent("notifications/cancelled").map { |message| message["params"] }

  def called(method) = @server.sent(method).first["id"]
end
