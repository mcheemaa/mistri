# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/stub_server"

# The remote MCP boundary: unsafe URL forms and non-public DNS answers fail
# before any request can carry credentials or invoke an internal service.
class TestMcpEgress < Minitest::Test
  def test_rejects_non_http_absolute_and_ambiguous_urls
    urls = [
      "file:///etc/passwd",
      "/mcp",
      "https:///mcp",
      "https://exa mple.com/mcp",
      "https://user:secret@example.com/mcp",
      "https://example.com/mcp#fragment",
      "https://example.com:99999/mcp"
    ]

    urls.each do |url|
      assert_raises(Mistri::MCP::UnsafeURLError, url) do
        Mistri::MCP::Client.new(url: url)
      end
    end
  end

  def test_normalizes_case_default_ports_and_root_paths
    egress = Mistri::MCP.const_get(:Egress, false)

    assert_equal "https://example.com", egress.normalize("HTTPS://EXAMPLE.COM:443/").to_s
  end

  def test_default_rejects_every_class_of_non_public_address
    egress = Mistri::MCP.const_get(:Egress, false)
    urls = [
      "https://127.1/mcp",
      "https://2130706433/mcp",
      "https://0x7f000001/mcp",
      "https://017700000001/mcp",
      "https://10.1.2.3/mcp",
      "https://100.64.0.1/mcp",
      "https://169.254.169.254/latest/meta-data",
      "https://192.0.2.1/mcp",
      "https://198.18.0.1/mcp",
      "https://224.0.0.1/mcp",
      "https://[::1]/mcp",
      "https://[::ffff:127.0.0.1]/mcp",
      "https://[fc00::1]/mcp",
      "https://[fe80::1]/mcp",
      "https://[2001:db8::1]/mcp"
    ]

    urls.each do |url|
      assert_raises(Mistri::MCP::UnsafeURLError, url) do
        egress.target(url)
      end
    end
  end

  def test_iana_more_specific_global_exceptions_remain_reachable
    egress = Mistri::MCP.const_get(:Egress, false)

    assert egress.globally_reachable?(IPAddr.new("192.0.0.9"))
    assert egress.globally_reachable?(IPAddr.new("192.31.196.1"))
    assert egress.globally_reachable?(IPAddr.new("2001:1::1"))
    assert egress.globally_reachable?(IPAddr.new("2620:4f:8000::1"))
    assert egress.globally_reachable?(IPAddr.new("2606:4700:4700::1111"))
    refute egress.globally_reachable?(IPAddr.new("4000::1"))
  end

  def test_nat64_addresses_inherit_the_embedded_ipv4_policy
    egress = Mistri::MCP.const_get(:Egress, false)

    refute egress.globally_reachable?(IPAddr.new("64:ff9b::a9fe:a9fe"))
    assert egress.globally_reachable?(IPAddr.new("64:ff9b::808:808"))
    refute egress.globally_reachable?(IPAddr.new("::ffff:127.0.0.1"))
    assert egress.globally_reachable?(IPAddr.new("::ffff:8.8.8.8"))
  end

  def test_loopback_http_requires_an_explicit_narrow_exception
    egress = Mistri::MCP.const_get(:Egress, false)
    target = egress.target("http://127.1/mcp",
                           allow_non_public: Mistri::Test::ALLOW_LOOPBACK)

    assert_equal "127.0.0.1", target.address
    assert_raises(Mistri::MCP::UnsafeURLError) do
      egress.target("http://127.1/mcp")
    end
    assert_raises(Mistri::MCP::UnsafeURLError) do
      egress.target("http://10.0.0.1/mcp",
                    allow_non_public: ->(_uri, _address) { true })
    end
  end

  def test_internal_https_can_be_approved_by_host_and_range
    network = IPAddr.new("10.20.0.0/16")
    seen = []
    allow_internal = lambda do |uri, address|
      seen << [uri.hostname, address]
      uri.hostname == "10.20.1.4" && network.include?(address)
    end

    egress = Mistri::MCP.const_get(:Egress, false)
    target = egress.target("HTTPS://10.20.1.4:443/mcp", allow_non_public: allow_internal)

    assert_equal "10.20.1.4", seen.first.first
    assert_equal IPAddr.new("10.20.1.4"), seen.first.last
    assert_equal "https://10.20.1.4/mcp", target.uri.to_s
  end

  def test_empty_and_mixed_dns_answers_fail_closed
    egress = Mistri::MCP.const_get(:Egress, false)
    uri = egress.normalize("https://mixed.example/mcp")
    answers = [IPAddr.new("93.184.216.34"), IPAddr.new("127.0.0.1")]

    assert_raises(Mistri::MCP::UnsafeURLError) do
      egress.approved_addresses(uri, [])
    end
    assert_raises(Mistri::MCP::UnsafeURLError) do
      egress.approved_address(uri, answers)
    end
  end

  def test_dns_failure_and_non_callable_exceptions_fail_closed
    egress = Mistri::MCP.const_get(:Egress, false)
    failures = [SocketError.new("missing"), IOError.new("failed"), Timeout::Error.new("slow")]

    failures.each do |failure|
      lookup = ->(*, **) { raise failure }

      assert_raises(Mistri::MCP::UnsafeURLError) do
        egress.target("https://missing.invalid/mcp", lookup: lookup)
      end
    end
    assert_raises(Mistri::MCP::UnsafeURLError) do
      egress.target("https://empty.example/mcp", lookup: ->(*, **) { [] })
    end

    assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP::Client.new(url: "https://example.com/mcp", allow_non_public: true)
    end
  end

  def test_malformed_dns_answers_fail_closed
    egress = Mistri::MCP.const_get(:Egress, false)
    malformed = Object.new
    malformed.define_singleton_method(:ip_address) { "not-an-address" }

    assert_raises(Mistri::MCP::UnsafeURLError) do
      egress.target("https://malformed.example/mcp", lookup: ->(*, **) { [malformed] })
    end
  end

  def test_client_construction_is_lazy_but_eagerly_rejects_known_bad_input
    policy = ->(*) { flunk "construction resolved DNS" }
    client = Mistri::MCP::Client.new(url: "https://127.0.0.1/mcp",
                                     allow_non_public: policy)
    client.close

    assert_raises(Mistri::MCP::UnsafeURLError) do
      Mistri::MCP::Client.new(url: "http://mcp.example/mcp")
    end
    assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP::Client.new(url: "https://mcp.example/mcp", allow_non_public: true)
    end
  end

  def test_redirect_uri_validation_uses_one_stable_snapshot
    values = ["https://app.example/callback", "http://internal.example/callback"]
    source = Object.new
    source.define_singleton_method(:to_s) { values.shift }

    assert_equal "https://app.example/callback",
                 Mistri::MCP.const_get(:Egress, false).redirect_uri(source)
    assert_equal ["http://internal.example/callback"], values
  end

  def test_redirect_uri_allows_only_https_or_explicit_loopback_http
    egress = Mistri::MCP.const_get(:Egress, false)

    assert_equal "http://localhost/callback", egress.redirect_uri("http://localhost/callback")
    assert_equal "http://127.0.0.1/callback", egress.redirect_uri("http://127.0.0.1/callback")
    assert_equal "http://[::1]/callback", egress.redirect_uri("http://[::1]/callback")
    assert_raises(Mistri::MCP::UnsafeURLError) do
      egress.redirect_uri("http://internal.example/callback")
    end
    assert_raises(Mistri::MCP::UnsafeURLError) do
      egress.redirect_uri("http://10.0.0.1/callback")
    end
  end

  def test_policy_callback_cannot_mutate_the_dial_target
    egress = Mistri::MCP.const_get(:Egress, false)
    policy = lambda do |uri, address|
      uri.host.replace("changed.example")
      assert_raises(FrozenError) { address.prefix = 24 }
      true
    end
    target = egress.target("https://10.20.1.4/mcp", allow_non_public: policy)

    assert_equal "10.20.1.4", target.uri.hostname
    assert_equal "10.20.1.4", target.address
  end

  def test_approved_dns_answers_fail_over_before_sending_the_request
    transport = nil
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true })
    end
    egress = Mistri::MCP.const_get(:Egress, false)
    port = URI(server.origin).port
    dns_calls = 0
    lookup = lambda do |*, **|
      dns_calls += 1
      [Addrinfo.tcp("::1", port), Addrinfo.tcp("127.0.0.1", port)]
    end

    uri, resolver = egress.resolver("http://mcp.example:#{port}/mcp",
                                    allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                    lookup: lookup)
    transport = Mistri::Transport.new(origin: egress.origin(uri),
                                      address_resolver: resolver, open_timeout: 1)

    assert_equal({ "ok" => true }, transport.post("/mcp", body: {}))

    assert_equal 1, dns_calls
    assert_equal 1, server.requests.length
    assert_equal "mcp.example:#{port}", server.requests.first[:headers]["host"]
  ensure
    transport&.close
    server&.stop
  end

  def test_internal_keep_alive_reconnect_revalidates_dns
    transport = nil
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true }, headers: { "Connection" => "close" })
    end
    egress = Mistri::MCP.const_get(:Egress, false)
    port = URI(server.origin).port
    answers = [
      [Addrinfo.tcp("127.0.0.1", port)],
      [Addrinfo.tcp("127.0.0.1", port), Addrinfo.tcp("10.0.0.1", port)]
    ]
    lookup = ->(*, **) { answers.shift || flunk("unexpected DNS lookup") }

    uri, resolver = egress.resolver("http://mcp.example:#{port}/mcp",
                                    allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                    lookup: lookup)
    transport = Mistri::Transport.new(origin: egress.origin(uri),
                                      address_resolver: resolver)

    assert_equal({ "ok" => true }, transport.post("/mcp", body: {}))
    assert_raises(Mistri::MCP::UnsafeURLError) do
      transport.post("/mcp", body: {})
    end

    assert_empty answers
    assert_equal 1, server.requests.length
  ensure
    transport&.close
    server&.stop
  end

  def test_plain_http_and_reserved_headers_cannot_bypass_the_boundary
    assert_raises(Mistri::MCP::UnsafeURLError) do
      Mistri::MCP::Client.new(url: "http://mcp.example.com/mcp",
                              headers: { "authorization" => "Bearer secret" })
    end
    assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP::Client.new(url: "http://127.0.0.1/mcp",
                              headers: { "hOsT" => "internal" },
                              allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
    end
  end

  def test_malformed_custom_header_names_cannot_smuggle_managed_headers
    names = ["X-Test\r\nHost", "X-Test\nTransfer-Encoding", "X:Test", "X Test", "X\0Test",
             "Host ", "Transfer-Encoding "]

    names.each do |name|
      assert_raises(Mistri::ConfigurationError, name.inspect) do
        Mistri::MCP::Client.new(url: "https://mcp.example/mcp",
                                headers: { name => "value" })
      end
    end
  end

  def test_custom_header_values_reject_control_characters
    ["line\rbreak", "line\nbreak", "nul\0byte", "tab\tvalue", "delete\x7Fvalue"].each do |value|
      assert_raises(Mistri::ConfigurationError, value.inspect) do
        Mistri::MCP::Client.new(url: "https://mcp.example/mcp",
                                headers: { "X-Test" => value })
      end
    end
  end
end
