# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"

# The stream of one call: when it is left, when its connection is kept, and
# how the client goes back to one that ended before its answer.
class TestMcpHttpStreams < Minitest::Test
  ECHO = lambda do |server, socket, id|
    server.open(socket)
    server.event(socket, server.answer(id, "echo"))
    server.finish(socket)
  end
  LINGERS = lambda do |server, socket, id|
    server.open(socket)
    server.event(socket, server.answer(id, "at once"))
    sleep 1
    server.finish(socket)
  end
  CHATTERS = lambda do |server, socket, id|
    server.open(socket)
    server.event(socket, server.answer(id, "at once"))
    40.times do
      server.raw(socket, ": still open\n\n")
      sleep 0.025
    end
    server.finish(socket)
  end
  FLOODS = lambda do |server, socket, id|
    server.open(socket)
    server.event(socket, server.answer(id, "at once"))
    stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    server.raw(socket, ": again\n\n") while Process.clock_gettime(Process::CLOCK_MONOTONIC) < stop
    :close
  end
  # Ends the stream before the answer, as a server that wants the client back.
  LEAVES = lambda do |wait, unfinished = ""|
    lambda do |server, socket, _id|
      server.open(socket)
      server.raw(socket, "id: e1\nretry: #{wait}\ndata: \n\n#{unfinished}")
      server.finish(socket)
    end
  end
  ENDS = lambda do |server, socket, _id|
    server.open(socket)
    server.event(socket, { "jsonrpc" => "2.0", "method" => "notifications/message" })
    server.finish(socket)
  end
  TOOLS = { "echo" => ECHO, "lingers" => LINGERS, "chatters" => CHATTERS, "floods" => FLOODS,
            "ends" => ENDS,
            "leaves" => LEAVES.call(100), "leaves_long" => LEAVES.call(5000),
            "leaves_mid_event" => LEAVES.call(50, "id: bad\0\n\nid: so\rX: y\n\nid: e2\n") }.freeze
  # Answers the call the client came back for, on the stream of the GET.
  RESUMES = lambda do |server, socket, _request|
    server.open(socket)
    answer = JSON.generate(server.answer(server.calling, "resumed"))
    server.raw(socket, "id: e9\ndata: #{answer}\n\n")
    server.finish(socket)
  end
  SILENT = lambda do |server, socket, _request|
    server.open(socket)
    sleep 1
    :close
  end

  def teardown
    @client&.close
    @server&.stop
  end

  def test_a_call_returns_at_its_answer_when_the_stream_stays_open
    %w[lingers chatters floods].each do |tool|
      client.connect
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = @client.call_tool(tool, {})
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal "at once", result.dig("content", 0, "text"), tool
      assert_operator elapsed, :<, 0.6, tool
      assert_equal "echo", @client.call_tool("echo", {}).dig("content", 0, "text"), tool
      assert_equal 2, @server.accepts, "the stream that stayed open lost its connection"
      teardown
    end
  end

  def test_a_stream_that_ends_with_its_answer_keeps_its_connection
    2.times { client_once.call_tool("echo", {}) }

    assert_equal 1, @server.accepts
  end

  def test_a_client_with_no_read_timeout_reads_a_stream
    result = client(read_timeout: nil).call_tool("echo", {})

    assert_equal "echo", result.dig("content", 0, "text")
  end

  def test_a_stream_that_ended_early_is_resumed_after_the_wait_the_server_named
    client(on_get: RESUMES).connect
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = @client.call_tool("leaves", {})
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    came_back = @server.requests("GET")

    assert_equal "resumed", result.dig("content", 0, "text")
    assert_operator elapsed, :>=, 0.1
    assert_equal(["e1"], came_back.map { |request| request[:headers]["last-event-id"] })
    assert_equal "s1", came_back.first[:headers]["mcp-session-id"]
    assert_equal 1, @server.sent("tools/call").length
  end

  def test_an_id_counts_when_its_event_has_ended
    result = client(on_get: RESUMES).call_tool("leaves_mid_event", {})
    came_back = @server.requests("GET")

    assert_equal "resumed", result.dig("content", 0, "text")
    assert_equal(["e1"], came_back.map { |request| request[:headers]["last-event-id"] })
  end

  def test_a_stream_with_no_event_id_is_not_resumed
    error = assert_raises(Mistri::AmbiguousDeliveryError) do
      client(on_get: RESUMES).call_tool("ends", {})
    end

    assert_match(%r{sent no matching response to tools/call}, error.message)
    assert_empty @server.requests("GET")
  end

  def test_a_wait_longer_than_the_read_timeout_is_not_waited
    client(read_timeout: 1, on_get: RESUMES).connect
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Mistri::AmbiguousDeliveryError) { @client.call_tool("leaves_long", {}) }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    assert_empty @server.requests("GET")
  end

  def test_a_resume_that_is_refused_leaves_the_call_unanswered_and_sends_it_once
    error = assert_raises(Mistri::AmbiguousDeliveryError) { client.call_tool("leaves", {}) }

    assert_match(/sent no matching response/, error.message)
    assert_equal 1, @server.requests("GET").length
    assert_equal 1, @server.sent("tools/call").length
  end

  def test_a_resumed_stream_that_stays_silent_times_out
    client(read_timeout: 0.3, on_get: SILENT).connect

    error = assert_raises(Mistri::AmbiguousDeliveryError) { @client.call_tool("leaves", {}) }

    assert_match(/timed out waiting for the MCP server/, error.message)
    assert_equal 1, @server.sent("notifications/cancelled").length
  end

  def test_a_retry_that_is_no_number_is_not_taken
    events = Mistri::MCP::Wires::Http.const_get(:Events).new

    events.feed("retry: soon\nid: e1\n\n") { flunk "no record was sent" }

    assert_nil events.retry_after
    assert_equal "e1", events.last_event_id
  end

  private

  def client(read_timeout: 10, **)
    @server = Mistri::Test::McpScriptedServer.new(tools: TOOLS, **)
    @client = Mistri::MCP::Client.new(url: @server.url, read_timeout: read_timeout,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
  end

  def client_once = @client || client
end
