# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/oauth_stub_server"
require "digest"
require "socket"
require "uri"

# The OAuth services against a real socket: discovery both ways, dynamic
# registration as the application, PKCE-correct authorize URLs, code
# exchange, and rotating refresh.
class TestMcpOauth < Minitest::Test # rubocop:disable Metrics/ClassLength -- one real-socket flow
  def with_server(**)
    server = Mistri::Test::OauthStubServer.new(**)
    yield server
  ensure
    server.stop
  end

  def start_flow(server, **options)
    options[:issuer] = server.origin if options[:client_id] && !options.key?(:issuer)
    Mistri::MCP::OAuth.start(url: server.url, client_name: "Sendoso",
                             redirect_uri: "https://app.example.com/mcp/callback",
                             allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **options)
  end

  def test_start_discovers_registers_and_builds_a_pkce_authorize_url
    with_server do |server|
      flow = start_flow(server)

      registration = server.registrations.first

      assert_equal "Sendoso", registration["client_name"],
                   "registration happens as the application, never the harness"
      assert_equal ["https://app.example.com/mcp/callback"], registration["redirect_uris"]
      assert_equal "client_secret_basic", registration["token_endpoint_auth_method"]

      assert_equal "app-123", flow["client_id"]
      assert_equal server.origin, flow["issuer"]
      assert_equal "#{server.origin}/token", flow["token_endpoint"]

      query = URI.decode_www_form(URI(flow["authorize_url"]).query).to_h

      assert_equal "code", query["response_type"]
      assert_equal server.url, query["resource"]
      assert_equal flow["state"], query["state"]
      assert_equal "S256", query["code_challenge_method"]

      expected = Digest::SHA256.base64digest(flow["code_verifier"]).tr("+/", "-_").delete("=")

      assert_equal expected, query["code_challenge"], "the challenge hashes the verifier"
    end
  end

  def test_discovery_falls_back_to_the_well_known_path
    with_server(challenge_header: false) do |server|
      flow = start_flow(server)

      assert_equal "app-123", flow["client_id"]
    end
  end

  def test_openid_configuration_serves_as_metadata_fallback
    with_server(openid_only: true) do |server|
      flow = start_flow(server)

      assert_equal "#{server.origin}/token", flow["token_endpoint"]
    end
  end

  def test_authorization_server_discovery_requires_metadata
    with_server(oauth_metadata_status: 404) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_equal "no authorization server metadata at #{server.origin}", error.message
    end
  end

  def test_metadata_discovery_advances_after_non_success_responses
    with_server(challenge_header: false, path_metadata_status: 500,
                root_metadata: true, oauth_metadata_status: 405,
                openid_only: true) do |server|
      flow = start_flow(server)

      assert_equal server.origin, flow["issuer"]
      paths = server.requests.filter_map do |request|
        verb, path, = request[:line].split
        path if verb == "GET"
      end

      assert_includes paths, "/.well-known/oauth-protected-resource"
      assert_includes paths, "/.well-known/openid-configuration"
    end
  end

  def test_well_known_urls_keep_resource_query_and_issuer_path_order
    assert_equal [
      "https://mcp.example/.well-known/oauth-protected-resource/public/mcp?tenant=one",
      "https://mcp.example/.well-known/oauth-protected-resource"
    ], Mistri::MCP::OAuth.well_known_resource_urls(
      "https://mcp.example/public/mcp?tenant=one"
    )
    assert_equal [
      "https://auth.example/.well-known/oauth-authorization-server/tenant",
      "https://auth.example/.well-known/openid-configuration/tenant",
      "https://auth.example/tenant/.well-known/openid-configuration"
    ], Mistri::MCP::OAuth.authorization_metadata_urls("https://auth.example/tenant")
  end

  def test_a_pre_registered_client_skips_registration
    with_server do |server|
      flow = start_flow(server, client_id: "static-9", client_secret: "s")

      assert_equal "static-9", flow["client_id"]
      assert_empty server.registrations
    end
  end

  def test_pre_registered_clients_require_an_exact_host_selected_issuer
    with_server do |server|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::MCP::OAuth.start(
          url: server.url, client_name: "App",
          redirect_uri: "https://app.example/callback", client_id: "static"
        )
      end
      assert_match(/issuer/, error.message)

      ["#{server.origin}/", server.origin.upcase].each do |issuer|
        error = assert_raises(Mistri::MCP::Error) do
          start_flow(server, client_id: "static", client_secret: "secret", issuer: issuer)
        end
        assert_match(/configured issuer/, error.message)
      end
      assert_empty server.registrations
    end
  end

  def test_client_credentials_cannot_exist_without_a_client_id
    common = { url: "https://mcp.example/mcp", client_name: "App",
               redirect_uri: "https://app.example/callback" }

    assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP::OAuth.start(**common, client_secret: "secret")
    end
    assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP::OAuth.start(**common, token_auth_method: "none")
    end
  end

  def test_registration_arguments_have_strict_shapes_and_relationships
    common = { url: "https://mcp.example/mcp", client_name: "App",
               redirect_uri: "https://app.example/callback" }
    cases = [
      [{ client_id: " " }, "client_id: must be a non-empty string"],
      [{ client_id: "id", client_secret: "", issuer: "https://auth.example" },
       "client_secret: must be a non-empty string"],
      [{ issuer: "" }, "issuer: must be a non-empty string"],
      [{ token_auth_method: "private_key_jwt" },
       'unsupported token endpoint authentication method "private_key_jwt"'],
      [{ client_id: "id", client_secret: "secret", token_auth_method: "none",
         issuer: "https://auth.example" },
       "token_auth_method: none cannot be paired with client_secret:"]
    ]

    cases.each do |options, message|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::MCP::OAuth.start(**common, **options)
      end

      assert_equal message, error.message
    end
  end

  def test_multiple_authorization_servers_require_host_selection
    with_server(authorization_servers: lambda { |server|
      ["https://unused.example", server.origin]
    }) do |server|
      assert_raises(Mistri::ConfigurationError) { start_flow(server) }

      flow = start_flow(server, issuer: server.origin)

      assert_equal server.origin, flow["issuer"]
    end
  end

  def test_authorization_servers_must_be_a_nonempty_array_of_strings
    [[], "https://auth.example", [nil], [""]].each do |advertised|
      with_server(authorization_servers: ->(_server) { advertised }) do |server|
        error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

        assert_equal "protected resource metadata names no authorization servers",
                     error.message
      end
    end
  end

  def test_duplicate_authorization_servers_are_one_choice
    with_server(authorization_servers: lambda { |server|
      [server.origin, server.origin]
    }) do |server|
      assert_equal server.origin, start_flow(server)["issuer"]
    end
  end

  def test_redirect_uri_is_validated_without_changing_its_exact_value
    with_server do |server|
      redirect_uri = "https://app.example.com:443/"
      flow = Mistri::MCP::OAuth.start(
        url: server.url, client_name: "Sendoso", redirect_uri: redirect_uri,
        allow_non_public: Mistri::Test::ALLOW_LOOPBACK
      )
      query = URI.decode_www_form(URI(flow["authorize_url"]).query).to_h

      assert_equal redirect_uri, flow["redirect_uri"]
      assert_equal redirect_uri, server.registrations.first["redirect_uris"].first
      assert_equal redirect_uri, query["redirect_uri"]
    end
  end

  def test_authorize_url_replaces_server_supplied_oauth_parameters
    with_server(endpoints: { "authorization_endpoint" => lambda { |server|
      "#{server.origin}/authorize?tenant=one&client_id=evil&scope=admin" \
        "&redirect_uri=https://evil.example"
    } }) do |server|
      flow = start_flow(server)
      pairs = URI.decode_www_form(URI(flow["authorize_url"]).query)

      tenants = pairs.filter_map { |key, value| value if key == "tenant" }
      client_ids = pairs.filter_map do |key, value|
        value if key == "client_id"
      end

      assert_equal ["one"], tenants
      assert_equal [flow["client_id"]], client_ids
      expected = "https://app.example.com/mcp/callback"
      redirects = pairs.filter_map { |key, value| value if key == "redirect_uri" }

      assert_equal [expected], redirects
      refute(pairs.any? { |key, _value| key == "scope" })
    end
  end

  def test_a_server_without_registration_fails_with_instructions
    with_server(registration: false) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_match(/pass client_id:/, error.message)
    end
  end

  def test_complete_exchanges_the_code_with_verifier_and_resource
    with_server do |server|
      flow = start_flow(server)
      tokens = Mistri::MCP::OAuth.complete(code: "good-code",
                                           allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                           **flow.transform_keys(&:to_sym))

      assert_equal "at-1", tokens["access_token"]
      assert_equal "rt-1", tokens["refresh_token"]
      assert_in_delta Time.now.utc + 3600, tokens["expires_at"], 10

      exchange = server.token_requests.first

      assert_equal flow["code_verifier"], exchange["code_verifier"]
      assert_equal server.url, exchange["resource"]
      assert_equal "https://app.example.com/mcp/callback", exchange["redirect_uri"]
      assert_equal "shh", exchange["client_secret"]
    end
  end

  def test_complete_requires_the_persisted_issuer
    with_server do |server|
      flow = start_flow(server).transform_keys(&:to_sym)
      flow.delete(:issuer)

      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::MCP::OAuth.complete(code: "good-code",
                                    allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **flow)
      end

      assert_match(/persist flow\["issuer"\]/, error.message)
      assert_empty server.token_requests
    end
  end

  def test_refresh_rotates_the_refresh_token
    with_server do |server|
      flow = start_flow(server)
      tokens = Mistri::MCP::OAuth.refresh(refresh_token: "rt-1",
                                          allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                          **flow.transform_keys(&:to_sym))

      assert_equal "at-2", tokens["access_token"]
      assert_equal "rt-2", tokens["refresh_token"], "OAuth 2.1 rotation persists"
    end
  end

  def test_token_operations_rediscover_the_endpoint_from_the_bound_issuer
    metadata_calls = 0
    endpoint = lambda do |server|
      metadata_calls += 1
      metadata_calls == 1 ? "#{server.origin}/old-token" : "#{server.origin}/token"
    end
    with_server(endpoints: { "token_endpoint" => endpoint }) do |server|
      flow = start_flow(server)

      assert_equal "#{server.origin}/old-token", flow["token_endpoint"]

      tokens = Mistri::MCP::OAuth.complete(
        code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
        **flow.transform_keys(&:to_sym)
      )

      assert_equal "at-1", tokens["access_token"]
      assert_equal 2, metadata_calls
    end
  end

  def test_issuer_mismatch_during_completion_sends_no_credentials
    metadata_calls = 0
    issuer = lambda do |server|
      metadata_calls += 1
      metadata_calls == 1 ? server.origin : "https://other.example"
    end
    with_server(issuer: issuer) do |server|
      flow = start_flow(server)

      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.complete(
          code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
          **flow.transform_keys(&:to_sym)
        )
      end

      assert_match(/issuer does not match/, error.message)
      assert_empty server.token_requests
    end
  end

  def test_scopes_default_from_the_resource_without_adding_privileges
    with_server(resource_scopes: ["tools:read"],
                as_scopes: %w[tools:read offline_access]) do |server|
      flow = start_flow(server)
      query = URI.decode_www_form(URI(flow["authorize_url"]).query).to_h

      assert_equal "tools:read", query["scope"]
    end
  end

  def test_an_explicit_scope_is_host_policy
    with_server do |server|
      flow = start_flow(server, scope: "tools offline_access")
      query = URI.decode_www_form(URI(flow["authorize_url"]).query).to_h

      assert_equal "tools offline_access", query["scope"]
    end
  end

  def test_malformed_resource_scopes_fail_closed
    with_server(resource_scopes: ["tools:read", nil]) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_equal "protected resource scopes_supported is malformed", error.message
    end
  end

  def test_client_secret_basic_authenticates_the_token_request
    with_server(basic_token_auth: true) do |server|
      flow = start_flow(server)
      Mistri::MCP::OAuth.complete(code: "good-code",
                                  allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                  **flow.transform_keys(&:to_sym))

      exchange = server.token_requests.first

      assert_nil exchange["client_secret"], "the secret never rides the form in basic mode"
      expected = "Basic #{["app-123:shh"].pack("m0")}"

      assert_equal expected, exchange["_authorization"]
    end
  end

  def test_authorization_server_endpoints_must_be_https
    metadata = { "authorization_endpoint" => "http://evil.example/authorize",
                 "token_endpoint" => "https://as.example/token" }
    error = assert_raises(Mistri::MCP::UnsafeURLError) do
      Mistri::MCP::OAuth.validate_endpoints(metadata)
    end

    assert_match(/HTTPS/, error.message)
  end

  def test_a_bad_code_surfaces_the_servers_reason
    with_server do |server|
      flow = start_flow(server)
      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.complete(code: "wrong",
                                    allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                    **flow.transform_keys(&:to_sym))
      end

      assert_match(/invalid_grant/, error.message)
    end
  end

  def test_token_errors_never_reflect_attacker_controlled_descriptions
    reflected = "client_secret=shh&refresh_token=rt-1"
    with_server(token_error_description: reflected) do |server|
      flow = start_flow(server)
      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.complete(
          code: "wrong", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
          **flow.transform_keys(&:to_sym)
        )
      end

      assert_match(/invalid_grant/, error.message)
      refute_includes error.message, reflected
    end
  end

  def test_token_errors_only_surface_standard_error_codes
    reflected = "shh"
    with_server(token_error: reflected) do |server|
      flow = start_flow(server)
      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.complete(
          code: "wrong", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
          **flow.transform_keys(&:to_sym)
        )
      end

      assert_equal "token request failed (400)", error.message
      refute_includes error.message, reflected
    end
  end

  def test_token_type_is_required_and_must_be_bearer
    [nil, "", 7, "shh"].each do |token_type|
      response = { "access_token" => "at" }
      response["token_type"] = token_type unless token_type.nil?
      with_server(token_response: response) do |server|
        flow = start_flow(server)
        error = assert_raises(Mistri::MCP::Error) do
          Mistri::MCP::OAuth.complete(
            code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
            **flow.transform_keys(&:to_sym)
          )
        end

        assert_equal "token endpoint returned unsupported token_type", error.message
        refute_includes(error.message, token_type) if token_type.is_a?(String) && !token_type.empty?
      end
    end

    with_server(token_response: { "access_token" => "at", "token_type" => "bearer" }) do |server|
      flow = start_flow(server)
      tokens = Mistri::MCP::OAuth.complete(
        code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
        **flow.transform_keys(&:to_sym)
      )

      assert_equal "at", tokens["access_token"]
    end
  end

  def test_token_response_requires_a_string_access_token
    [nil, "", { "nested" => "token" }].each do |access_token|
      response = { "access_token" => access_token, "token_type" => "Bearer" }
      with_server(token_response: response) do |server|
        flow = start_flow(server)
        error = assert_raises(Mistri::MCP::Error) do
          Mistri::MCP::OAuth.complete(
            code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
            **flow.transform_keys(&:to_sym)
          )
        end

        assert_match(/access_token/, error.message)
      end
    end
  end

  def test_oauth_responses_are_bounded_and_never_request_compression
    limit = Mistri::MCP::OAuth.const_get(:MAX_RESPONSE_BYTES, false)
    oversized = "x" * (limit + 1)
    with_server(token_response: oversized) do |server|
      flow = start_flow(server)
      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.complete(
          code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
          **flow.transform_keys(&:to_sym)
        )
      end

      assert_match(/exceeded/, error.message)
      assert(server.requests.all? do |request|
        request[:headers]["accept-encoding"] == "identity"
      end)
    end
  end

  def test_discovery_tries_path_then_root
    with_server(challenge_header: false, path_metadata: false, root_metadata: true) do |server|
      flow = start_flow(server)
      paths = server.requests.filter_map do |request|
        verb, path, = request[:line].split
        path if verb == "GET" && path.include?("oauth-protected-resource")
      end

      assert_equal "app-123", flow["client_id"]
      assert_equal ["/.well-known/oauth-protected-resource/mcp",
                    "/.well-known/oauth-protected-resource"], paths
    end
  end

  def test_the_challenge_scope_precedes_broader_resource_metadata
    with_server(challenge_scope: "tools:write", resource_scopes: ["tools:all"]) do |server|
      flow = start_flow(server)
      query = URI.decode_www_form(URI(flow["authorize_url"]).query).to_h

      assert_equal "tools:write", query["scope"]
    end
  end

  def test_an_explicit_scope_may_add_to_the_challenged_scope
    with_server(challenge_scope: "tools:read tools:write") do |server|
      flow = start_flow(server, scope: "tools:admin tools:write tools:read")
      query = URI.decode_www_form(URI(flow["authorize_url"]).query).to_h

      assert_equal "tools:admin tools:write tools:read", query["scope"]
    end
  end

  def test_an_explicit_scope_cannot_omit_a_challenged_scope
    with_server(challenge_scope: "tools:read tools:write") do |server|
      error = assert_raises(Mistri::ConfigurationError) do
        start_flow(server, scope: "tools:read")
      end

      assert_equal "scope: must include every scope required by the MCP challenge",
                   error.message
      assert_empty server.registrations
    end
  end

  def test_protected_resource_metadata_is_bound_to_the_server
    with_server(resource: "https://other.example/mcp") do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_match(/does not match/, error.message)
    end
  end

  def test_root_metadata_identifies_the_origin_without_widening_the_token_audience
    with_server(challenge_header: false, path_metadata: false, root_metadata: true,
                query: "tenant=one") do |server|
      flow = start_flow(server)
      query = URI.decode_www_form(URI(flow["authorize_url"]).query).to_h
      Mistri::MCP::OAuth.complete(
        code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
        **flow.transform_keys(&:to_sym)
      )

      assert_equal server.url, flow["resource"]
      assert_equal server.url, query["resource"]
      assert_equal server.url, server.token_requests.first["resource"]
    end
  end

  def test_path_metadata_rejects_ancestor_and_queryless_resources
    with_server(resource: lambda(&:origin)) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_match(/does not match/, error.message)
    end
    with_server(query: "tenant=one", resource: ->(server) { "#{server.origin}/mcp" }) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_match(/does not match/, error.message)
    end
  end

  def test_authorization_server_metadata_is_bound_to_its_issuer
    with_server(issuer: "https://other.example") do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_match(/issuer does not match/, error.message)
    end
  end

  def test_pkce_support_must_be_advertised_as_s256
    [nil, ["plain"], "S256"].each do |methods|
      with_server(pkce: methods) do |server|
        error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

        assert_match(/S256 PKCE/, error.message)
      end
    end
  end

  def test_redirect_uri_must_be_https_or_loopback
    error = assert_raises(Mistri::MCP::UnsafeURLError) do
      Mistri::MCP::OAuth.start(url: "https://mcp.example/mcp", client_name: "App",
                               redirect_uri: "http://app.example/callback")
    end

    assert_match(/redirect_uri/, error.message)
  end

  def test_every_discovered_endpoint_obeys_the_same_network_policy
    with_server do |server|
      base = { "authorization_endpoint" => "#{server.origin}/authorize",
               "token_endpoint" => "#{server.origin}/token" }
      %w[authorization_endpoint token_endpoint registration_endpoint].each do |key|
        metadata = base.merge(key => "https://169.254.169.254/secret")

        assert_raises(Mistri::MCP::UnsafeURLError, key) do
          Mistri::MCP::OAuth.validate_endpoints(
            metadata, allow_non_public: Mistri::Test::ALLOW_LOOPBACK
          )
        end
      end
    end
  end

  def test_oauth_requests_ignore_ambient_proxies
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
    egress = Mistri::MCP.const_get(:Egress, false)
    port = URI(server.origin).port
    lookup = ->(*, **) { [Addrinfo.tcp("127.0.0.1", port)] }
    targets = egress.targets("http://oauth.example:#{port}/metadata",
                             allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                             lookup: lookup)

    response = Mistri::MCP::OAuth.http(targets, Net::HTTP::Get.new(targets.first.uri))

    assert_equal "200", response.code
    assert_equal 1, server.requests.length
    assert_empty proxy.requests
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    server&.stop
    proxy&.stop
  end

  def test_oauth_tries_an_approved_alternate_before_sending_the_request
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.respond_json(socket, { "ok" => true })
    end
    egress = Mistri::MCP.const_get(:Egress, false)
    port = URI(server.origin).port
    lookup = lambda do |*, **|
      [Addrinfo.tcp("::1", port), Addrinfo.tcp("127.0.0.1", port)]
    end
    targets = egress.targets("http://oauth.example:#{port}/metadata",
                             allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                             lookup: lookup)
    request = Net::HTTP::Get.new(targets.first.uri)

    response = Mistri::MCP::OAuth.http(targets, request)

    assert_equal "200", response.code
    assert_equal 1, server.requests.length
  ensure
    server&.stop
  end

  def test_metadata_discovery_falls_back_after_a_connection_failure
    server = Mistri::Test::StubServer.new do |socket, request|
      path = request[:line].split[1]
      if path == "/.well-known/oauth-authorization-server"
        :close
      else
        server.respond_json(socket, { "issuer" => server.origin,
                                      "token_endpoint" => "#{server.origin}/token" })
      end
    end

    metadata = Mistri::MCP::OAuth.server_metadata(
      server.origin, allow_non_public: Mistri::Test::ALLOW_LOOPBACK
    )

    assert_equal "#{server.origin}/token", metadata["token_endpoint"]
    assert_equal 2, server.requests.length
  ensure
    server&.stop
  end

  def test_first_exact_issuer_metadata_document_is_authoritative
    server = Mistri::Test::StubServer.new do |socket, request|
      verb, path, = request[:line].split
      if path == "/.well-known/oauth-authorization-server"
        server.respond_json(socket, { "issuer" => server.origin })
      elsif path == "/.well-known/openid-configuration"
        server.respond_json(socket, { "issuer" => server.origin,
                                      "token_endpoint" => "#{server.origin}/token" })
      elsif verb == "POST" && path == "/token"
        server.respond_json(socket, { "access_token" => "unexpected",
                                      "token_type" => "Bearer" })
      end
    end

    error = assert_raises(Mistri::MCP::Error) do
      Mistri::MCP::OAuth.complete(
        code: "code", code_verifier: "verifier", client_id: "client",
        resource: "#{server.origin}/mcp", redirect_uri: "https://app.example/callback",
        issuer: server.origin, token_auth_method: "none",
        allow_non_public: Mistri::Test::ALLOW_LOOPBACK
      )
    end

    assert_equal "authorization server metadata has no token_endpoint", error.message
    assert_equal 1, server.requests.length
  ensure
    server&.stop
  end

  def test_required_metadata_fetch_rejects_connection_failure_and_invalid_json
    server = Mistri::Test::StubServer.new do |socket, request|
      if request[:line].include?("/dropped")
        :close
      else
        server.respond_json(socket, "not-json")
      end
    end

    error = assert_raises(Mistri::MCP::Error) do
      Mistri::MCP::OAuth.get_json(
        "#{server.origin}/dropped", allow_non_public: Mistri::Test::ALLOW_LOOPBACK
      )
    end
    assert_equal "OAuth connection failed", error.message

    error = assert_raises(Mistri::MCP::Error) do
      Mistri::MCP::OAuth.get_json(
        "#{server.origin}/invalid", allow_non_public: Mistri::Test::ALLOW_LOOPBACK
      )
    end
    assert_match(/returned invalid JSON/, error.message)
  ensure
    server&.stop
  end

  def test_registration_http_errors_are_fixed_and_bounded
    server = Mistri::Test::StubServer.new do |socket, request|
      if request[:line].include?("/rejected")
        server.respond_json(socket, { "error" => "secret detail" }, status: 400)
      else
        server.respond_json(socket, "not-json")
      end
    end

    cases = [["rejected", /answered 400/], ["invalid", /returned invalid JSON/]]
    cases.each do |path, message|
      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.post_json(
          "#{server.origin}/#{path}", { "client_name" => "App" },
          allow_non_public: Mistri::Test::ALLOW_LOOPBACK
        )
      end

      assert_match message, error.message
      refute_includes error.message, "secret detail"
    end
  ensure
    server&.stop
  end

  def test_invalid_json_from_the_token_endpoint_has_a_fixed_error
    server = Mistri::Test::StubServer.new do |socket, request|
      verb, path, = request[:line].split
      if verb == "GET"
        server.respond_json(socket, { "issuer" => server.origin,
                                      "token_endpoint" => "#{server.origin}/token" })
      elsif path == "/token"
        server.respond_json(socket, "not-json")
      end
    end

    error = assert_raises(Mistri::MCP::Error) do
      Mistri::MCP::OAuth.complete(
        code: "good-code", code_verifier: "verifier", client_id: "client",
        resource: "#{server.origin}/mcp", redirect_uri: "https://app.example/callback",
        issuer: server.origin, token_auth_method: "none",
        allow_non_public: Mistri::Test::ALLOW_LOOPBACK
      )
    end

    assert_equal "token endpoint returned invalid JSON", error.message
    refute_includes error.message, "not-json"
  ensure
    server&.stop
  end

  def test_a_dropped_oauth_metadata_response_is_not_retried
    server = Mistri::Test::StubServer.new do |socket, _request|
      if server.requests.one?
        :close
      else
        server.respond_json(socket, { "ok" => true })
      end
    end
    egress = Mistri::MCP.const_get(:Egress, false)
    port = URI(server.origin).port
    lookup = ->(*, **) { [Addrinfo.tcp("127.0.0.1", port)] }
    targets = egress.targets("http://oauth.example:#{port}/metadata",
                             allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                             lookup: lookup)
    request = Net::HTTP::Get.new(targets.first.uri)

    error = assert_raises(Mistri::MCP::Error) do
      Mistri::MCP::OAuth.http(targets, request)
    end

    assert_match(/connection failed/i, error.message)
    assert_equal 1, server.accepts
    assert_equal 1, server.requests.length
  ensure
    server&.stop
  end

  def test_protocol_exceptions_never_reflect_remote_text
    reflected = "client_secret=shh"
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      socket.each_line { |line| break if line == "\r\n" }
      socket.write("#{reflected}\r\n\r\n")
    ensure
      socket&.close
    end
    uri = URI("http://oauth.example:#{server.local_address.ip_port}/token")
    target = Struct.new(:uri, :address).new(uri, "127.0.0.1")

    error = assert_raises(Mistri::MCP::Error) do
      Mistri::MCP::OAuth.http([target], Net::HTTP::Get.new(target.uri))
    end

    assert_equal "OAuth connection failed", error.message
    refute_includes error.message, reflected
  ensure
    server&.close
    if thread
      thread.join(1)
      thread.kill if thread.alive?
    end
  end

  def test_private_challenge_and_authorization_server_urls_are_rejected
    with_server(challenge_metadata: "https://169.254.169.254/metadata") do |server|
      assert_raises(Mistri::MCP::UnsafeURLError) { start_flow(server) }
    end
    with_server(authorization_server: "https://10.0.0.1") do |server|
      assert_raises(Mistri::MCP::UnsafeURLError) { start_flow(server) }
    end
  end

  def test_persisted_token_endpoint_cannot_redirect_credentials
    with_server do |server|
      flow = start_flow(server)
      persisted = flow.transform_keys(&:to_sym)
                      .merge(token_endpoint: "https://169.254.169.254/token")
      tokens = Mistri::MCP::OAuth.complete(
        code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **persisted
      )

      assert_equal "at-1", tokens["access_token"]
      assert_equal 1, server.token_requests.length
    end
  end

  def test_metadata_redirects_are_not_followed
    with_server(metadata_redirect: "https://169.254.169.254/metadata") do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_match(/no protected resource metadata/, error.message)
      assert_equal 2, server.requests.length
    end
  end

  def test_a_preregistered_secret_defaults_to_basic_auth
    with_server do |server|
      flow = start_flow(server, client_id: "static:id", client_secret: "s/e cret")
      Mistri::MCP::OAuth.complete(code: "good-code",
                                  allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                  **flow.transform_keys(&:to_sym))
      exchange = server.token_requests.first

      assert_nil exchange["client_secret"]
      encoded = "static%3Aid:s%2Fe+cret"

      assert_equal "Basic #{[encoded].pack("m0")}", exchange["_authorization"]
    end
  end

  def test_a_preregistered_client_can_explicitly_use_secret_post
    with_server do |server|
      flow = start_flow(server, client_id: "static", client_secret: "secret",
                                token_auth_method: "client_secret_post")
      Mistri::MCP::OAuth.complete(code: "good-code",
                                  allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                                  **flow.transform_keys(&:to_sym))
      exchange = server.token_requests.first

      assert_equal "secret", exchange["client_secret"]
      assert_nil exchange["_authorization"]
    end
  end

  def test_legacy_nil_token_auth_method_keeps_secret_post
    with_server do |server|
      flow = start_flow(server)
      persisted = flow.transform_keys(&:to_sym)
      persisted.delete(:token_auth_method)
      Mistri::MCP::OAuth.complete(
        code: "good-code", allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **persisted
      )

      exchange = server.token_requests.first

      assert_equal "shh", exchange["client_secret"]
      assert_nil exchange["_authorization"]
    end
  end

  def test_registration_rejects_secret_authentication_without_a_secret
    options = { registration_secret: nil, registration_auth_method: "client_secret_basic" }
    with_server(**options) do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_match(/without a client_secret/, error.message)
    end
  end

  def test_registration_rejects_a_secret_for_an_unauthenticated_client
    with_server(registration_auth_method: "none", registration_secret: "unexpected") do |server|
      error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

      assert_equal "registration returned a client_secret for an unauthenticated client",
                   error.message
    end
  end

  def test_authorization_server_token_auth_methods_must_be_an_array_of_strings
    ["client_secret_basic", [nil]].each do |supported|
      with_server(token_auth_methods: supported) do |server|
        error = assert_raises(Mistri::MCP::Error) { start_flow(server) }

        assert_equal "authorization server token auth methods are malformed", error.message
      end
    end
  end

  def test_a_preregistered_secret_auth_method_without_a_secret_fails_before_network
    with_server do |server|
      error = assert_raises(Mistri::ConfigurationError) do
        start_flow(server, client_id: "static", token_auth_method: "client_secret_basic")
      end

      assert_equal "client_secret_basic requires a client_secret", error.message
      assert_empty server.requests
    end
  end

  def test_token_auth_methods_fail_closed_and_none_rejects_a_secret
    with_server do |server|
      flow = start_flow(server)
      params = flow.transform_keys(&:to_sym).merge(token_auth_method: "none",
                                                   client_secret: "do-not-send",
                                                   allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.complete(code: "good-code", **params)
      end
      assert_match(/cannot use a client_secret/, error.message)
      assert_empty server.token_requests

      unknown = flow.transform_keys(&:to_sym).merge(token_auth_method: "private_key_jwt",
                                                    allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.refresh(refresh_token: "rt-1", **unknown)
      end
      assert_match(/unsupported token endpoint authentication/, error.message)
      assert_empty server.token_requests
    end
  end
end
