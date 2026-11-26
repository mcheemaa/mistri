# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"

# What the 2026-07-28 form changes in a call: a server may answer by asking
# for input, sends no request of its own, and is cancelled by a closed stream.
class TestMcpStateless < Minitest::Test
  NEWEST = { "supportedVersions" => ["2026-07-28"] }.freeze
  ASKS = { "resultType" => "input_required", "requestState" => "opaque",
           "inputRequests" => { "confirm" => { "method" => "elicitation/create",
                                               "params" => { "message" => "Please confirm" } },
                                "roots" => { "method" => "roots/list" },
                                "odd" => "not a request" } }.freeze
  TOOLS = {
    "asks" => ->(server, socket, id) { server.result(socket, id, ASKS) },
    "strange" => lambda { |server, socket, id|
      server.result(socket, id, { "resultType" => "partial" })
    },
    "requests" => lambda do |server, socket, id|
      server.open(socket)
      server.event(socket, { "jsonrpc" => "2.0", "id" => "srv-1", "method" => "ping" })
      server.event(socket, server.answer(id, "done"))
      server.finish(socket)
    end,
    "comments" => lambda do |server, socket, _id|
      server.open(socket)
      40.times do
        server.raw(socket, ": still here\n\n")
        sleep 0.03
      end
      :close
    end,
    "leaves" => lambda do |server, socket, _id|
      server.open(socket)
      server.raw(socket, "id: e1\nretry: 10\ndata: \n\n")
      server.finish(socket)
    end
  }.freeze

  def teardown
    @client&.close
    @server&.stop
  end

  def test_a_call_that_waits_for_input_ends_as_the_tools_own_error
    result = client.call_tool("asks", {})

    assert result["isError"]
    assert_equal "The server asked for input before it would finish this call " \
                 "(elicitation/create: Please confirm; roots/list). This client gives a server " \
                 "no input, so the call was not finished.", result.dig("content", 0, "text")
    assert_equal 1, @server.sent("tools/call").length
  end

  def test_a_result_that_carries_only_state_is_sent_again_with_it
    rounds = [{ "resultType" => "input_required", "requestState" => "one" },
              { "resultType" => "input_required" }, nil]
    tool = lambda do |server, socket, id|
      server.result(socket, id, rounds.shift || server.answer(id, "done")["result"])
    end

    result = client({ "turns" => tool }).call_tool("turns", { "n" => 1 })
    calls = @server.sent("tools/call")

    assert_equal "done", result.dig("content", 0, "text")
    assert_equal([nil, "one", nil], calls.map { |call| call.dig("params", "requestState") })
    assert_equal([false, true, false], calls.map { |call| call["params"].key?("requestState") })
    assert_equal 3, calls.map { |call| call["id"] }.uniq.length
    assert_equal([{ "n" => 1 }] * 3, calls.map { |call| call.dig("params", "arguments") })
  end

  def test_a_server_that_keeps_asking_to_be_called_again_is_given_up
    tool = lambda do |server, socket, id|
      server.result(socket, id, { "resultType" => "input_required", "requestState" => "more" })
    end

    result = client({ "loops" => tool }).call_tool("loops", {})

    assert result["isError"]
    assert_match(/asked for input before it would finish this call\. This client/,
                 result.dig("content", 0, "text"))
    assert_equal 4, @server.sent("tools/call").length
  end

  def test_a_result_of_an_unknown_type_is_refused
    error = assert_raises(Mistri::MCP::Error) { client.call_tool("strange", {}) }

    assert_equal 'the server returned a result of the unknown type "partial"', error.message
  end

  def test_a_request_from_the_server_gets_no_reply
    result = client.call_tool("requests", {})

    assert_equal "done", result.dig("content", 0, "text")
    assert_empty(@server.posted.reject { |message| message.key?("method") })
  end

  def test_a_timeout_sends_no_cancel_because_the_closed_stream_is_one
    client(read_timeout: 0.3).tools

    error = assert_raises(Mistri::AmbiguousDeliveryError) { @client.call_tool("comments", {}) }

    assert_match(/timed out waiting for the MCP server/, error.message)
    assert_empty @server.sent("notifications/cancelled")
  end

  def test_a_stream_that_ended_early_is_not_asked_for_again
    assert_raises(Mistri::AmbiguousDeliveryError) { client.call_tool("leaves", {}) }

    assert_empty @server.requests("GET")
  end

  private

  def client(extra = {}, read_timeout: 10)
    @server = Mistri::Test::McpScriptedServer.new(tools: TOOLS.merge(extra), discover: NEWEST)
    @client = Mistri::MCP::Client.new(url: @server.url, read_timeout: read_timeout,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
  end
end
