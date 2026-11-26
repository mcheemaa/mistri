# frozen_string_literal: true

require "json"
require "timeout"
require_relative "test_helper"
require_relative "support/stub_server"

# A request the host ends before its response was read. The error a Timeout
# raises is no StandardError, so nothing on the way out closed the connection.
class TestTransportLeftRequests < Minitest::Test
  def setup
    @count = 0
    @transport = nil
  end

  def teardown
    @transport&.close
    @server.stop
  end

  def test_a_json_request_left_half_way_does_not_answer_the_next_one
    @server = Mistri::Test::StubServer.new do |socket, _request|
      number = (@count += 1)
      sleep 0.3 if number == 1
      @server.respond_json(socket, { "n" => number })
    end
    @transport = Mistri::Transport.new(origin: @server.origin)

    assert_raises(Timeout::Error) { Timeout.timeout(0.1) { @transport.post("/x", body: {}) } }

    assert_equal({ "n" => 2 }, @transport.post("/x", body: {}))
    assert_equal 2, @server.accepts
  end

  def test_a_stream_left_half_way_does_not_answer_the_next_one
    serve_slow_stream
    seen = []

    assert_raises(Timeout::Error) do
      Timeout.timeout(0.1) { @transport.stream_post("/x", body: {}) { |record| seen << record } }
    end
    @transport.stream_post("/x", body: {}) { |record| seen << record }

    assert_equal [{ "n" => 1 }, { "n" => 2 }, { "n" => 2, "last" => true }], seen
    assert_equal 2, @server.accepts
  end

  def test_an_mcp_response_left_half_way_does_not_answer_the_next_one
    serve_slow_stream
    seen = []

    keep = lambda do |record|
      seen << record
      nil
    end

    assert_raises(Timeout::Error) { Timeout.timeout(0.1) { @transport.post_either("/x", body: {}, &keep) } }
    @transport.post_either("/x", body: {}, &keep)

    assert_equal [{ "n" => 1 }, { "n" => 2 }, { "n" => 2, "last" => true }], seen
    assert_equal 2, @server.accepts
    assert_equal 2, @server.requests.length, "the second request was sent once"
  end

  private

  def serve_slow_stream
    @server = Mistri::Test::StubServer.new do |socket, _request|
      number = (@count += 1)
      @server.start_sse(socket)
      @server.sse_data(socket, { "n" => number })
      sleep 0.3 if number == 1
      @server.sse_data(socket, { "n" => number, "last" => true })
      @server.finish_sse(socket)
    end
    @transport = Mistri::Transport.new(origin: @server.origin)
  end
end
