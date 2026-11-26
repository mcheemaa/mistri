# frozen_string_literal: true

# The cases for application_type, for the address of a client ID metadata
# document, for the issuer of a callback and for a resource that covers a
# path are adapted from the tests of the Model Context Protocol Ruby SDK
# (test/mcp/client/oauth), Apache License 2.0. See NOTICE.

require_relative "test_helper"
require_relative "support/oauth_stub_server"
require "uri"

# The checks a sign-in makes beyond discovery and exchange: the issuer of a
# callback, what a registration returned, how the application names itself,
# a typed token error, more scope, and what tolerant discovery accepts.
class TestMcpOauthChecks < Minitest::Test # rubocop:disable Metrics/ClassLength -- one real-socket flow
  OAUTH = Mistri::MCP::OAuth
  ISS = { "authorization_response_iss_parameter_supported" => true }.freeze
  DOCUMENT = "https://app.example.com/oauth/client.json"
  TAKES_DOCUMENT = { "client_id_metadata_document_supported" => true }.freeze

  def with_server(**)
    server = Mistri::Test::OauthStubServer.new(**)
    yield server
  ensure
    server.stop
  end

  def start_flow(server, **)
    OAUTH.start(url: server.url, client_name: "Example App",
                redirect_uri: "https://app.example.com/mcp/callback",
                allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **)
  end

  def complete(flow, **)
    OAUTH.complete(code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                   **flow.transform_keys(&:to_sym), **)
  end

  # -- the issuer of a callback ----------------------------------------------

  def test_a_callback_from_the_issuer_of_the_sign_in_is_exchanged
    with_server(endpoints: ISS) do |server|
      tokens = complete(start_flow(server), iss: server.origin)

      assert_equal "at-1", tokens["access_token"]
    end
  end

  def test_a_callback_that_names_another_issuer_sends_no_code
    with_server(endpoints: ISS) do |server|
      flow = start_flow(server)
      ["https://other.example", "#{server.origin}/", server.origin.upcase,
       [server.origin]].each do |iss|
        error = assert_raises(Mistri::MCP::Error) { complete(flow, iss: iss) }

        assert_equal "the authorization response's iss is not the issuer of this sign-in",
                     error.message
      end
      assert_empty server.token_requests
    end
  end

  def test_a_callback_with_no_iss_is_refused_when_the_server_says_it_sends_one
    with_server(endpoints: ISS) do |server|
      flow = start_flow(server)
      [nil, ""].each do |iss|
        error = assert_raises(Mistri::MCP::Error) { complete(flow, iss: iss) }

        assert_equal "the authorization response has no iss, which its server says it sends",
                     error.message
      end
      assert_empty server.token_requests
    end
  end

  def test_a_callback_with_no_iss_goes_on_when_the_server_does_not_say_it_sends_one
    with_server do |server|
      assert_equal "at-1", complete(start_flow(server), iss: nil)["access_token"]
    end
    said_in_a_string = { "authorization_response_iss_parameter_supported" => "true" }

    with_server(endpoints: said_in_a_string) do |server|
      assert_equal "at-1", complete(start_flow(server), iss: nil)["access_token"]
    end
  end

  def test_an_iss_is_compared_even_when_the_server_does_not_say_it_sends_one
    with_server do |server|
      assert_raises(Mistri::MCP::Error) { complete(start_flow(server), iss: "https://other.example") }
      assert_empty server.token_requests
    end
  end

  def test_a_host_that_hands_over_no_iss_gets_no_check
    with_server(endpoints: ISS) do |server|
      assert_equal "at-1", complete(start_flow(server))["access_token"]
    end
  end

  # -- registration -----------------------------------------------------------

  def test_a_secret_with_no_method_named_is_not_kept_by_a_client_that_asked_for_none
    with_server(registration_auth_method: false, token_auth_methods: ["none"]) do |server|
      flow = start_flow(server)

      assert_equal ["app-123", nil, "none"],
                   flow.values_at("client_id", "client_secret", "token_auth_method")

      complete(flow)
      exchange = server.token_requests.first

      assert_equal "app-123", exchange["client_id"]
      assert_nil exchange["client_secret"]
      assert_nil exchange["_authorization"]
    end
  end

  def test_a_secret_with_no_method_named_is_presented_the_way_the_client_asked
    with_server(registration_auth_method: false) do |server|
      flow = start_flow(server)

      assert_equal %w[shh client_secret_basic], flow.values_at("client_secret", "token_auth_method")

      complete(flow)

      assert_equal "Basic #{["app-123:shh"].pack("m0")}",
                   server.token_requests.first["_authorization"]
    end
  end

  def test_a_registration_with_no_secret_and_no_method_is_a_public_client
    with_server(registration_auth_method: false, registration_secret: nil) do |server|
      assert_equal ["app-123", nil, "none"],
                   start_flow(server).values_at("client_id", "client_secret", "token_auth_method")
    end
  end

  def test_a_registration_with_no_client_id_is_refused
    with_server(registration_client_id: nil) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_equal "registration returned no client_id", error.message
    end
  end

  def test_a_registration_says_what_kind_of_application_it_is_for
    with_server do |server|
      start_flow(server)
      OAUTH.start(url: server.url, client_name: "Example App",
                  redirect_uri: "http://127.0.0.1:53682/callback",
                  allow_non_public: Mistri::Test::ALLOW_LOOPBACK)

      assert_equal(%w[web native], server.registrations.map { |sent| sent["application_type"] })
    end
  end

  def test_a_loopback_redirect_is_a_native_application_and_any_other_a_web_one
    %w[http://localhost:0/callback http://127.0.0.1:8080/cb http://[::1]/cb
       https://LOCALHOST/cb].each do |uri|
      assert_equal "native", OAUTH.application_type(uri), uri
    end
    %w[https://app.example.com/callback https://localhost.example.com/cb
       https://127.0.0.1.example.com/cb].each do |uri|
      assert_equal "web", OAUTH.application_type(uri), uri
    end
  end

  # -- the client ID metadata document ---------------------------------------

  def test_a_server_that_takes_a_document_gets_its_address_as_the_client_id
    with_server(endpoints: TAKES_DOCUMENT) do |server|
      flow = start_flow(server, client_metadata_url: DOCUMENT)

      assert_equal [DOCUMENT, nil, "none"],
                   flow.values_at("client_id", "client_secret", "token_auth_method")
      assert_equal DOCUMENT, URI.decode_www_form(URI(flow["authorize_url"]).query).to_h["client_id"]
      assert_empty server.registrations

      complete(flow)

      assert_equal DOCUMENT, server.token_requests.first["client_id"]
    end
  end

  def test_a_server_that_does_not_say_true_gets_a_registration
    [{}, { "client_id_metadata_document_supported" => "true" },
     { "client_id_metadata_document_supported" => false }].each do |metadata|
      with_server(endpoints: metadata) do |server|
        flow = start_flow(server, client_metadata_url: DOCUMENT)

        assert_equal "app-123", flow["client_id"]
        assert_equal 1, server.registrations.length
      end
    end
  end

  def test_a_client_set_up_by_hand_comes_before_the_document
    with_server(endpoints: TAKES_DOCUMENT) do |server|
      flow = start_flow(server, client_metadata_url: DOCUMENT, client_id: "static-9",
                                issuer: server.origin)

      assert_equal "static-9", flow["client_id"]
    end
  end

  def test_a_document_address_that_could_be_spelled_two_ways_is_refused_before_any_request
    with_server(endpoints: TAKES_DOCUMENT) do |server|
      error = assert_raises(Mistri::ConfigurationError) do
        start_flow(server, client_metadata_url: "https://app.example.com/client.json?v=2")
      end

      assert_match(/client_metadata_url:/, error.message)
      assert_empty server.requests
    end
  end

  def test_the_address_of_a_document_is_https_with_a_path_and_one_spelling
    %w[https://app.example.com/client-metadata.json https://app.example.com/path/to/cm
       https://app.example.com:8443/cm HTTPS://app.example.com/cm https://app.example.com/cm/
       https://app.example.com//cm https://app.example.com:443/cm https://[2001:db8::1]/cm
       https://xn--e1afmkfd.example.com/cm].each do |url|
      assert OAUTH.client_metadata_url?(url), "#{url} was refused"
    end
    [nil, "", "http://localhost/cm", "http://app.example.com/cm", "ftp://app.example.com/cm",
     "file:///cm", "https://app.example.com", "https://app.example.com/",
     "https://app.example.com/cm#frag", "https://app.example.com/cm?x=1",
     "https://user:pass@app.example.com/cm", "https://user@app.example.com/cm",
     "https://app.example.com/./cm", "https://app.example.com/a/../cm",
     "https://app.example.com/cm/.", "https://app.example.com/cm/..",
     "https://app.example.com/%2E/cm", "https://app.example.com/%2e/cm",
     "https://[invalid/cm"].each do |url|
      refute OAUTH.client_metadata_url?(url), "#{url.inspect} was taken"
    end
  end

  def test_the_document_a_host_serves_matches_what_a_sign_in_sends
    document = OAUTH.client_metadata(url: DOCUMENT, client_name: "Example App",
                                     redirect_uris: "https://app.example.com/mcp/callback")

    assert_equal({ "client_id" => DOCUMENT, "client_name" => "Example App",
                   "redirect_uris" => ["https://app.example.com/mcp/callback"],
                   "grant_types" => %w[authorization_code refresh_token],
                   "response_types" => ["code"], "token_endpoint_auth_method" => "none" }, document)
    assert_raises(Mistri::ConfigurationError) do
      OAUTH.client_metadata(url: "https://app.example.com/", client_name: "A", redirect_uris: [])
    end
    assert_raises(Mistri::MCP::UnsafeURLError) do
      OAUTH.client_metadata(url: DOCUMENT, client_name: "A", redirect_uris: ["http://app.example/cb"])
    end
  end

  # -- bound to the issuer ---------------------------------------------------

  def test_a_client_whose_issuer_the_server_no_longer_names_is_told_apart
    with_server do |server|
      error = assert_raises(OAUTH::IssuerChanged) do
        start_flow(server, client_id: "registered-earlier", issuer: "https://earlier.example")
      end

      assert_kind_of Mistri::MCP::Error, error
      assert_empty server.registrations
    end
  end

  # -- a refused token request -----------------------------------------------

  def test_a_spent_grant_has_its_own_error
    with_server do |server|
      error = assert_raises(OAUTH::InvalidGrantError) do
        OAUTH.refresh(refresh_token: "spent", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                      **start_flow(server).transform_keys(&:to_sym))
      end

      assert_equal [400, "invalid_grant", "token request failed (400): invalid_grant"],
                   [error.status, error.reason, error.message]
      assert_kind_of OAUTH::TokenError, error
    end
  end

  def test_another_standard_code_is_a_token_error_that_names_it
    with_server(token_error: "invalid_client") do |server|
      error = assert_raises(OAUTH::TokenError) { OAUTH.complete(**wrong_code(server)) }

      assert_instance_of OAUTH::TokenError, error
      assert_equal [400, "invalid_client"], [error.status, error.reason]
    end
  end

  def test_a_code_that_is_not_a_standard_one_is_not_passed_on
    [nil, 42, true, [], ["invalid_grant"], { "secret" => "hidden" }, "", "invalid_grant\n",
     "provider_extension"].each do |code|
      with_server(token_error: code) do |server|
        error = assert_raises(OAUTH::TokenError) { OAUTH.complete(**wrong_code(server)) }

        assert_instance_of OAUTH::TokenError, error, code.inspect
        assert_equal [400, nil, "token request failed (400)"],
                     [error.status, error.reason, error.message]
      end
    end
  end

  # -- more scope ------------------------------------------------------------

  def test_a_refusal_hands_over_its_challenge
    header = 'Basic realm="x", Bearer error="insufficient_scope", scope="files:write", ' \
             'resource_metadata="https://mcp.example/.well-known/oauth-protected-resource"'
    error = Mistri::AuthenticationError.new(status: 403, challenge: header)

    assert_equal({ "error" => "insufficient_scope", "scope" => "files:write",
                   "resource_metadata" =>
                     "https://mcp.example/.well-known/oauth-protected-resource" },
                 OAUTH.challenge(error))
    assert_empty OAUTH.challenge(Mistri::AuthenticationError.new(status: 403))
    assert_empty OAUTH.challenge(Mistri::ProviderError.new(status: 500))
  end

  def test_a_step_up_asks_for_what_was_granted_and_what_is_asked
    assert_equal "mcp:read mcp:write", OAUTH.step_up_scope("mcp:read", "mcp:write")
    assert_equal "a b c", OAUTH.step_up_scope("a b", "b  c")
    assert_equal "mcp:write", OAUTH.step_up_scope(nil, "mcp:write")
    assert_nil OAUTH.step_up_scope("mcp:read", nil)
    assert_nil OAUTH.step_up_scope("mcp:read", " ")
  end

  def test_a_step_up_scope_is_what_the_next_sign_in_asks_for
    with_server(challenge_scope: "mcp:basic") do |server|
      flow = start_flow(server, scope: OAUTH.step_up_scope("mcp:basic", "mcp:write"))

      assert_equal "mcp:basic mcp:write",
                   URI.decode_www_form(URI(flow["authorize_url"]).query).to_h["scope"]
    end
  end

  # -- offline_access --------------------------------------------------------

  def test_offline_access_is_added_when_the_host_asks_and_the_server_lists_it
    with_server(resource_scopes: ["tools:read"],
                as_scopes: %w[tools:read offline_access]) do |server|
      assert_equal "tools:read offline_access", scope_of(start_flow(server, offline_access: true))
      assert_equal "tools:read", scope_of(start_flow(server))
      assert_equal "offline_access tools:read",
                   scope_of(start_flow(server, offline_access: true,
                                               scope: "offline_access tools:read"))
    end
  end

  def test_offline_access_is_not_added_where_it_is_not_listed_or_has_nothing_to_join
    with_server(resource_scopes: ["tools:read"], as_scopes: ["tools:read"]) do |server|
      assert_equal "tools:read", scope_of(start_flow(server, offline_access: true))
    end
    with_server(as_scopes: ["offline_access"]) do |server|
      assert_nil scope_of(start_flow(server, offline_access: true))
    end
  end

  # -- reading only ----------------------------------------------------------

  def test_discover_reads_how_a_server_signs_in_and_registers_nothing
    with_server(challenge_scope: "tools:read",
                token_auth_methods: %w[none client_secret_post]) do |server|
      found = OAUTH.discover(url: server.url, allow_non_public: Mistri::Test::ALLOW_LOOPBACK)

      assert_equal [server.url, server.origin, "tools:read"],
                   found.values_at("resource", "issuer", "scope")
      assert_equal [server.origin], found["resource_metadata"]["authorization_servers"]
      assert_equal "#{server.origin}/register", found["server_metadata"]["registration_endpoint"]
      assert_equal %w[none client_secret_post],
                   found["server_metadata"]["token_endpoint_auth_methods_supported"]
      assert_empty server.registrations
    end
  end

  def test_discover_takes_the_issuer_a_host_chose
    with_server(authorization_servers: lambda { |server|
      [server.origin, "https://other.example"]
    }) do |server|
      options = { url: server.url, allow_non_public: Mistri::Test::ALLOW_LOOPBACK }

      assert_equal server.origin, OAUTH.discover(issuer: server.origin, **options)["issuer"]
      assert_raises(Mistri::ConfigurationError) { OAUTH.discover(**options) }
      assert_raises(Mistri::ConfigurationError) { OAUTH.discover(issuer: "", **options) }
    end
  end

  # -- revoking --------------------------------------------------------------

  def test_revoke_sends_the_token_to_the_endpoint_the_issuer_names
    revocation = { "revocation_endpoint" => ->(server) { "#{server.origin}/revoke" } }
    with_server(endpoints: revocation) do |server|
      flow = start_flow(server).transform_keys(&:to_sym)

      assert OAUTH.revoke(token: "rt-1", allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **flow)
      assert_equal [{ "token" => "rt-1", "client_id" => "app-123", "client_secret" => "shh",
                      "_authorization" => nil }], server.revocations
    end
  end

  def test_revoke_for_a_client_with_no_secret_sends_its_id_alone
    revocation = { "revocation_endpoint" => ->(server) { "#{server.origin}/revoke" } }
    with_server(endpoints: revocation) do |server|
      OAUTH.revoke(token: "at-1", client_id: "app-123", issuer: server.origin,
                   allow_non_public: Mistri::Test::ALLOW_LOOPBACK)

      assert_equal [{ "token" => "at-1", "client_id" => "app-123", "_authorization" => nil }],
                   server.revocations
    end
  end

  def test_revoke_says_when_a_server_has_no_endpoint_and_raises_when_it_refuses
    with_server do |server|
      flow = start_flow(server).transform_keys(&:to_sym)

      refute OAUTH.revoke(token: "rt-1", allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **flow)
    end
    revocation = { "revocation_endpoint" => ->(server) { "#{server.origin}/revoke" } }
    with_server(endpoints: revocation, revocation_status: 503) do |server|
      flow = start_flow(server).transform_keys(&:to_sym)
      error = assert_raises(OAUTH::TokenError) do
        OAUTH.revoke(token: "rt-1", allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **flow)
      end

      assert_equal [503, nil, "token revocation failed (503)"],
                   [error.status, error.reason, error.message]
    end
  end

  # -- tolerant discovery ----------------------------------------------------

  def test_a_resource_document_for_the_origin_is_refused_exactly_and_taken_tolerantly
    with_server(resource: lambda(&:origin)) do |server|
      assert_raises(Mistri::MCP::Error) { start_flow(server) }

      flow = start_flow(server, tolerant: true)

      assert_equal server.origin, flow["resource"]
      assert_equal server.origin,
                   URI.decode_www_form(URI(flow["authorize_url"]).query).to_h["resource"]
    end
  end

  def test_a_resource_covers_its_own_path_and_the_paths_below_it
    covered = [%w[https://srv.example https://srv.example/mcp],
               %w[https://srv.example/api https://srv.example/api/mcp],
               %w[https://srv.example/mcp https://srv.example/mcp],
               %w[https://srv.example/mcp https://srv.example/mcp?tenant=one],
               %w[https://srv.example/mcp?tenant=one https://srv.example/mcp?tenant=one]]

    covered.each { |resource, url| assert OAUTH.covers?(resource, url), "#{resource} #{url}" }

    apart = [%w[https://other.example https://srv.example/mcp],
             %w[http://srv.example https://srv.example/mcp],
             %w[https://srv.example:8443 https://srv.example/mcp],
             %w[https://srv.example/api https://srv.example/apiv2/mcp],
             %w[https://srv.example/mcp/deeper https://srv.example/mcp],
             %w[https://srv.example/mcp?tenant=evil https://srv.example/mcp?tenant=one],
             %w[https://srv.example/mcp?tenant=one https://srv.example/mcp]]

    apart.each { |resource, url| refute OAUTH.covers?(resource, url), "#{resource} #{url}" }
  end

  def test_an_issuer_one_slash_apart_is_refused_exactly_and_taken_tolerantly
    with_server(issuer: ->(server) { "#{server.origin}/" }) do |server|
      assert_raises(Mistri::MCP::Error) { start_flow(server) }

      flow = start_flow(server, tolerant: true)

      assert_equal "#{server.origin}/", flow["issuer"]
      assert_equal "at-1", complete(flow, iss: "#{server.origin}/")["access_token"]
    end
    with_server(issuer: ->(server) { "#{server.origin}//" }) do |server|
      assert_raises(Mistri::MCP::Error) { start_flow(server, tolerant: true) }
    end
  end

  def test_a_stored_issuer_one_slash_apart_is_the_same_only_tolerantly
    with_server do |server|
      stored = { client_id: "registered-earlier", issuer: "#{server.origin}/" }

      assert_raises(OAUTH::IssuerChanged) { start_flow(server, **stored) }

      flow = start_flow(server, tolerant: true, **stored)

      assert_equal ["registered-earlier", server.origin], flow.values_at("client_id", "issuer")
      assert_empty server.registrations
    end
    refute OAUTH.same_issuer?("https://as.example", nil)
  end

  def test_a_server_with_no_resource_document_signs_in_at_its_origin_only_tolerantly
    with_server(challenge_header: false, path_metadata: false) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_match(/no protected resource metadata/, error.message)

      flow = start_flow(server, tolerant: true)

      assert_equal [server.url, server.origin], flow.values_at("resource", "issuer")
      assert_equal "at-1", complete(flow, tolerant: true)["access_token"]
    end
  end

  def test_a_server_with_no_metadata_at_all_gets_the_endpoints_of_the_older_revision
    with_server(challenge_header: false, path_metadata: false,
                oauth_metadata_status: 404) do |server|
      flow = start_flow(server, tolerant: true)

      assert_equal "#{server.origin}/authorize", flow["authorize_url"][/\A[^?]+/]
      assert_equal "#{server.origin}/token", flow["token_endpoint"]
      assert_equal 1, server.registrations.length
      assert_raises(Mistri::MCP::Error) { complete(flow) }
      assert_equal "at-1", complete(flow, tolerant: true)["access_token"]

      refreshed = OAUTH.refresh(refresh_token: "rt-1", tolerant: true,
                                allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                **flow.transform_keys(&:to_sym))

      assert_equal "at-2", refreshed["access_token"]
    end
  end

  def test_a_document_that_is_no_json_object_is_an_error_exactly_and_a_miss_tolerantly
    pages = { "/list" => "[]", "/page" => "<html>" }
    server = Mistri::Test::StubServer.new do |socket, request|
      body = pages[request[:line].split[1]]
      if body
        server.respond_json(socket, body)
      else
        server.respond_json(socket, { "error" => "not found" }, status: 404)
      end
    end
    fetch = lambda do |path, **options|
      OAUTH.get_json("#{server.origin}#{path}", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                                **options)
    end

    assert_match(/did not return a JSON object/,
                 assert_raises(Mistri::MCP::Error) { fetch.call("/list") }.message)
    assert_match(/answered 404/, assert_raises(Mistri::MCP::Error) { fetch.call("/gone") }.message)

    missed = []

    assert_nil fetch.call("/list", optional: true, missed: missed)
    assert_nil fetch.call("/page", optional: true, missed: missed)
    assert_nil fetch.call("/gone", optional: true, missed: missed)
    assert_equal [:unreadable, :unreadable, 404], missed
  ensure
    server&.stop
  end

  def test_an_authorization_server_a_document_names_must_publish_its_metadata
    with_server(oauth_metadata_status: 404) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server, tolerant: true) }

      assert_match(/no authorization server metadata/, error.message)
      assert_empty server.registrations
    end
  end

  def test_a_document_that_could_not_be_read_is_not_taken_for_one_that_is_not_there
    with_server(challenge_header: false, path_metadata_status: 503) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server, tolerant: true) }

      assert_match(/no protected resource metadata/, error.message)
      assert_empty server.registrations
    end
    with_server(oauth_metadata_status: 429) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server, tolerant: true) }

      assert_match(/no authorization server metadata/, error.message)
    end
    assert OAUTH.unpublished?([404, 302, :unreadable])
    refute OAUTH.unpublished?([404, nil])
    refute OAUTH.unpublished?([500])
  end

  private

  def wrong_code(server)
    start_flow(server).transform_keys(&:to_sym)
                      .merge(code: "wrong", allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
  end

  def scope_of(flow) = URI.decode_www_form(URI(flow["authorize_url"]).query).to_h["scope"]
end
