# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

class TestTransport < Minitest::Test
  def test_streams_records_and_reuses_one_connection_across_turns
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "n" => server.requests.length })
      server.finish_sse(socket)
    end
    transport = Mistri::Transport.new(origin: server.origin)
    records = []

    2.times { transport.stream_post("/v1/x", body: {}) { |r| records << r } }

    assert_equal [{ "n" => 1 }, { "n" => 2 }], records
    assert_equal 1, server.accepts
  ensure
    teardown_all(transport, server)
  end

  def test_reconnects_once_when_the_server_dropped_the_idle_socket
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => server.accepts })
      :close
    end
    transport = Mistri::Transport.new(origin: server.origin)

    assert_equal({ "ok" => 1 }, transport.post("/v1/x", body: {}))
    assert_equal({ "ok" => 2 }, transport.post("/v1/x", body: {}))
    assert_equal 2, server.accepts
  ensure
    teardown_all(transport, server)
  end

  def test_maps_statuses_to_the_error_hierarchy
    statuses = [401, 529, 503]
    errors = [Mistri::AuthenticationError, Mistri::OverloadedError, Mistri::ServerError]
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "error" => "x" },
                          status: statuses[server.requests.length - 1])
    end
    transport = Mistri::Transport.new(origin: server.origin)

    errors.each do |error_class|
      error = assert_raises(error_class) { transport.post("/v1/x", body: {}) }

      assert_kind_of Mistri::ProviderError, error
    end
  ensure
    teardown_all(transport, server)
  end

  def test_rate_limit_carries_retry_after
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "error" => "slow down" }, status: 429,
                                                              headers: { "Retry-After" => "7" })
    end
    transport = Mistri::Transport.new(origin: server.origin)

    error = assert_raises(Mistri::RateLimitError) { transport.post("/v1/x", body: {}) }

    assert_in_delta 7.0, error.retry_after
    assert_includes error.body, "slow down"
  ensure
    teardown_all(transport, server)
  end

  def test_abort_closes_a_hung_stream_immediately
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "first" => true })
      sleep 60
    end
    transport = Mistri::Transport.new(origin: server.origin, read_timeout: 30)
    signal = Mistri::AbortSignal.new
    records = []

    aborter = Thread.new do
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      sleep 0.05 while records.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      signal.abort!(:stop)
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = transport.stream_post("/v1/x", body: {}, signal: signal) { |r| records << r }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    aborter.join

    assert_equal :aborted, result
    assert_operator elapsed, :<, 5
  ensure
    teardown_all(transport, server)
  end

  def test_a_late_abort_from_a_finished_turn_never_touches_the_next_turn
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "ok" => true })
      server.finish_sse(socket)
    end
    transport = Mistri::Transport.new(origin: server.origin)
    first_signal = Mistri::AbortSignal.new

    first_turn = []
    transport.stream_post("/v1/x", body: {}, signal: first_signal) { |r| first_turn << r }
    first_signal.abort!(:too_late)
    records = []
    result = transport.stream_post("/v1/x", body: {}) { |r| records << r }

    assert_nil result
    assert_equal [{ "ok" => true }], records
    assert_equal 1, server.accepts
  ensure
    teardown_all(transport, server)
  end

  def test_a_pretripped_signal_never_opens_a_connection
    server = Mistri::Test::StubServer.new { |_socket, _request| flunk "reached the server" }
    transport = Mistri::Transport.new(origin: server.origin)
    signal = Mistri::AbortSignal.new
    signal.abort!

    assert_equal :aborted, transport.stream_post("/v1/x", body: {}, signal: signal)
    assert_equal 0, server.accepts
  ensure
    teardown_all(transport, server)
  end

  private

  def teardown_all(transport, server)
    transport&.close
    server&.stop
  end
end
