# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"
require_relative "support/tls_stub_server"

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

  def test_a_resolved_address_is_pinned_without_changing_host_identity
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true })
    end
    port = URI(server.origin).port
    transport = Mistri::Transport.new(origin: "http://unresolvable.invalid:#{port}",
                                      address_resolver: -> { ["127.0.0.1"] })

    assert_equal({ "ok" => true }, transport.post("/v1/x", body: {}))
    assert_equal "unresolvable.invalid:#{port}", server.requests.first[:headers]["host"]
  ensure
    teardown_all(transport, server)
  end

  def test_approved_addresses_fail_over_before_the_request_is_sent
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true })
    end
    resolutions = 0
    resolver = lambda do
      resolutions += 1
      ["::1", "127.0.0.1"]
    end
    transport = Mistri::Transport.new(origin: server.origin, address_resolver: resolver,
                                      open_timeout: 1)

    assert_equal({ "ok" => true }, transport.post("/v1/x", body: {}))

    assert_equal 1, resolutions
    assert_equal 1, server.requests.length
  ensure
    teardown_all(transport, server)
  end

  def test_an_empty_resolved_address_set_fails_before_connecting
    transport = Mistri::Transport.new(origin: "http://mcp.example",
                                      address_resolver: -> { [] })

    error = assert_raises(Mistri::ConfigurationError) do
      transport.post("/v1/x", body: {})
    end

    assert_equal "address_resolver returned no addresses", error.message
  ensure
    transport&.close
  end

  def test_an_exhausted_resolved_connection_deadline_never_dials
    server = Mistri::Test::StubServer.new do |_socket, _request|
      flunk "reached the server"
    end
    transport = Mistri::Transport.new(origin: server.origin,
                                      address_resolver: -> { ["127.0.0.1"] },
                                      open_timeout: 0)

    error = assert_raises(Mistri::ProviderError) do
      transport.post("/v1/x", body: {})
    end

    assert_includes error.message, "all approved addresses timed out"
    assert_equal 0, server.accepts
  ensure
    teardown_all(transport, server)
  end

  def test_a_resolved_connection_can_disable_the_open_timeout
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true })
    end
    transport = Mistri::Transport.new(origin: server.origin,
                                      address_resolver: -> { ["127.0.0.1"] },
                                      open_timeout: nil)

    assert_equal({ "ok" => true }, transport.post("/v1/x", body: {}))
  ensure
    teardown_all(transport, server)
  end

  def test_a_healthy_resolved_keep_alive_does_not_resolve_again
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true })
    end
    port = URI(server.origin).port
    resolutions = 0
    resolver = lambda do
      resolutions += 1
      ["127.0.0.1"]
    end
    transport = Mistri::Transport.new(origin: "http://mcp.example:#{port}",
                                      address_resolver: resolver)

    2.times do
      assert_equal({ "ok" => true }, transport.post("/v1/x", body: {}))
    end

    assert_equal 1, resolutions
    assert_equal 1, server.accepts
    assert_equal 2, server.requests.length
  ensure
    teardown_all(transport, server)
  end

  def test_a_generic_transport_keeps_net_http_environment_proxy_behavior
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true })
    end
    transport = Mistri::Transport.new(origin: server.origin)

    assert_equal({ "ok" => true }, transport.post("/v1/x", body: {}))
    connection = transport.send(:connection)

    assert_instance_of Net::HTTP, connection
    assert_predicate connection, :proxy_from_env?
  ensure
    teardown_all(transport, server)
  end

  def test_a_resolved_transport_ignores_ambient_proxies
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true })
    end
    proxy = Mistri::Test::StubServer.new do |socket, _request|
      proxy.respond_json(socket, { "proxied" => true })
    end
    keys = %w[HTTP_PROXY http_proxy NO_PROXY no_proxy]
    previous = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV.update("HTTP_PROXY" => proxy.origin, "http_proxy" => proxy.origin,
               "NO_PROXY" => "", "no_proxy" => "")
    port = URI(server.origin).port
    transport = Mistri::Transport.new(origin: "http://mcp.example:#{port}",
                                      address_resolver: -> { ["127.0.0.1"] })

    assert_equal({ "ok" => true }, transport.post("/v1/x", body: {}))
    assert_empty proxy.requests
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    teardown_all(transport, server)
    proxy&.stop
  end

  def test_pinning_preserves_sni_and_certificate_hostname_verification
    server = Mistri::Test::TlsStubServer.new(hostname: "mcp.test")
    OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.add_cert(server.ca_certificate)
    transport = Mistri::Transport.new(origin: server.origin,
                                      address_resolver: -> { ["127.0.0.1"] })

    assert_equal({ "ok" => true }, transport.post("/mcp", body: {}))
    assert_equal "mcp.test", server.server_name
    assert_equal "mcp.test:#{URI(server.origin).port}",
                 server.requests.first[:headers]["host"]
  ensure
    transport&.close
    server&.stop
  end

  def test_pinning_rejects_a_certificate_for_a_different_hostname
    server = Mistri::Test::TlsStubServer.new(hostname: "mcp.test",
                                             certificate_hostname: "other.test")
    OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.add_cert(server.ca_certificate)
    transport = Mistri::Transport.new(origin: server.origin,
                                      address_resolver: -> { ["127.0.0.1"] })

    assert_raises(OpenSSL::SSL::SSLError) do
      transport.post("/mcp", body: {})
    end
    assert_empty server.requests
  ensure
    transport&.close
    server&.stop
  end

  private

  def teardown_all(transport, server)
    transport&.close
    server&.stop
  end
end
