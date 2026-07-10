# frozen_string_literal: true

require "json"
require "stringio"
require "zlib"
require_relative "test_helper"
require_relative "support/stub_server"

# Entity bodies and streaming records stay bounded without capping a stream.
class TestTransportLimits < Minitest::Test
  def test_json_bodies_are_bounded_and_identity_encoded
    exact = JSON.generate("value" => "x" * 20)
    oversized = JSON.generate("value" => "x" * 21)
    server = Mistri::Test::StubServer.new do |socket, _request|
      payload = server.requests.length == 1 ? exact : oversized
      server.respond_json(socket, payload)
    end
    transport = Mistri::Transport.new(origin: server.origin,
                                      max_record_bytes: exact.bytesize)

    assert_equal({ "value" => "x" * 20 }, transport.post("/v1/x", body: {}))
    error = assert_raises(Mistri::ResponseTooLargeError) do
      transport.post("/v1/x", body: {})
    end

    assert_equal :json_body, error.kind
    assert_equal exact.bytesize, error.limit
    assert_equal "identity", server.requests.first[:headers]["accept-encoding"]
  ensure
    teardown_all(transport, server)
  end

  def test_rejects_an_oversized_declared_body_without_waiting_for_it
    server = Mistri::Test::StubServer.new do |socket, _request|
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: 1000\r\n\r\n")
      sleep 60
    end
    transport = Mistri::Transport.new(origin: server.origin, max_record_bytes: 64,
                                      read_timeout: 30)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Mistri::ResponseTooLargeError) do
      transport.post("/v1/x", body: {})
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2
  ensure
    teardown_all(transport, server)
  end

  def test_bounds_a_chunked_body_and_reconnects_without_stale_bytes
    oversized = JSON.generate("value" => "x" * 100)
    server = Mistri::Test::StubServer.new do |socket, _request|
      if server.requests.length == 1
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Transfer-Encoding: chunked\r\n\r\n")
        server.chunk(socket, oversized.byteslice(0, 40))
        server.chunk(socket, oversized.byteslice(40..))
        server.finish_sse(socket)
      else
        server.respond_json(socket, { "clean" => true })
      end
    end
    transport = Mistri::Transport.new(origin: server.origin, max_record_bytes: 64)

    assert_raises(Mistri::ResponseTooLargeError) do
      transport.post("/v1/x", body: {})
    end
    assert_equal({ "clean" => true }, transport.post("/v1/x", body: {}))

    assert_equal 2, server.accepts
  ensure
    teardown_all(transport, server)
  end

  def test_identity_encoding_prevents_compressed_expansion
    compressed = StringIO.new
    Zlib::GzipWriter.wrap(compressed) do |gzip|
      gzip.write(JSON.generate("value" => "x" * 1000))
    end
    payload = compressed.string

    assert_operator payload.bytesize, :<, 64, "the wire body must fit below the limit"

    server = Mistri::Test::StubServer.new do |socket, _request|
      if server.requests.length == 1
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Content-Encoding: gzip\r\nContent-Length: #{payload.bytesize}\r\n\r\n")
        socket.write(payload)
      else
        server.respond_json(socket, { "clean" => true })
      end
    end
    transport = Mistri::Transport.new(origin: server.origin, max_record_bytes: 64)

    assert_raises(JSON::ParserError) { transport.post("/v1/x", body: {}) }
    assert_equal({ "clean" => true }, transport.post("/v1/x", body: {}))
    assert_equal 2, server.accepts
  ensure
    teardown_all(transport, server)
  end

  def test_error_bodies_stop_at_a_small_valid_preview_without_losing_status
    server = Mistri::Test::StubServer.new do |socket, _request|
      if server.requests.length == 1
        body = ("a" * 499) + ("€" * 1000)
        server.respond_json(socket, body,
                            status: 429, headers: { "Retry-After" => "2" })
      else
        server.respond_json(socket, { "clean" => true })
      end
    end
    transport = Mistri::Transport.new(origin: server.origin, max_record_bytes: 16)

    error = assert_raises(Mistri::RateLimitError) do
      transport.post("/v1/x", body: {})
    end

    assert_equal 500, error.body.bytesize
    assert_predicate error.body, :valid_encoding?
    assert_equal "?", error.body[-1]
    assert_in_delta 2.0, error.retry_after
    assert_equal({ "clean" => true }, transport.post("/v1/x", body: {}))
    assert_equal 2, server.accepts
  ensure
    teardown_all(transport, server)
  end

  def test_an_oversized_sse_line_keeps_prior_records_and_resets_the_connection
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      if server.requests.length == 1
        server.sse_data(socket, { "first" => true })
        server.chunk(socket, "data: #{"x" * 100}")
      else
        server.sse_data(socket, { "clean" => true })
        server.finish_sse(socket)
      end
    end
    transport = Mistri::Transport.new(origin: server.origin, max_record_bytes: 32)
    records = []

    error = assert_raises(Mistri::ResponseTooLargeError) do
      transport.stream_post("/v1/x", body: {}) { |record| records << record }
    end
    transport.stream_post("/v1/x", body: {}) { |record| records << record }

    assert_equal :sse_line, error.kind
    assert_equal [{ "first" => true }, { "clean" => true }], records
    assert_equal 2, server.accepts
  ensure
    teardown_all(transport, server)
  end

  def test_rejects_invalid_record_limits_before_connecting
    [nil, 0, -1, 1.5, "10"].each do |value|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::Transport.new(origin: "http://127.0.0.1", max_record_bytes: value)
      end

      assert_equal "max_record_bytes: must be a positive integer", error.message
    end
  end

  def test_provider_overflow_is_machine_readable_and_never_retried
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.chunk(socket, "data: #{"x" * 100}")
    end
    provider = Mistri::Providers::OpenAI.new(
      api_key: "test", model: "gpt-5.6", origin: server.origin, max_record_bytes: 32
    )
    retries = Mistri::RetryPolicy.new(attempts: 2, base: 0.0)
    agent = Mistri::Agent.new(provider: provider, retries: retries)

    result = agent.run("go")

    assert_predicate result, :errored?
    assert_equal({ "type" => "ResponseTooLargeError", "kind" => "sse_line", "limit" => 32 },
                 result.message.error)
    assert_equal 1, server.requests.length
  ensure
    provider&.close
    server&.stop
  end

  private

  def teardown_all(transport, server)
    transport&.close
    server&.stop
  end
end
