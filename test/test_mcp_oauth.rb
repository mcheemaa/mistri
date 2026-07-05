# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/oauth_stub_server"
require "digest"
require "uri"

# The OAuth services against a real socket: discovery both ways, dynamic
# registration as the application, PKCE-correct authorize URLs, code
# exchange, and rotating refresh.
class TestMcpOauth < Minitest::Test
  def with_server(**)
    server = Mistri::Test::OauthStubServer.new(**)
    yield server
  ensure
    server.stop
  end

  def start_flow(server, **)
    Mistri::MCP::OAuth.start(url: server.url, client_name: "Sendoso",
                             redirect_uri: "https://app.example.com/mcp/callback", **)
  end

  def test_start_discovers_registers_and_builds_a_pkce_authorize_url
    with_server do |server|
      flow = start_flow(server)

      registration = server.registrations.first

      assert_equal "Sendoso", registration["client_name"],
                   "registration happens as the application, never the harness"
      assert_equal ["https://app.example.com/mcp/callback"], registration["redirect_uris"]

      assert_equal "app-123", flow["client_id"]
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

  def test_a_pre_registered_client_skips_registration
    with_server do |server|
      flow = start_flow(server, client_id: "static-9", client_secret: "s")

      assert_equal "static-9", flow["client_id"]
      assert_empty server.registrations
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

  def test_refresh_rotates_the_refresh_token
    with_server do |server|
      flow = start_flow(server)
      tokens = Mistri::MCP::OAuth.refresh(refresh_token: "rt-1",
                                          **flow.transform_keys(&:to_sym))

      assert_equal "at-2", tokens["access_token"]
      assert_equal "rt-2", tokens["refresh_token"], "OAuth 2.1 rotation persists"
    end
  end

  def test_a_bad_code_surfaces_the_servers_reason
    with_server do |server|
      flow = start_flow(server)
      error = assert_raises(Mistri::MCP::Error) do
        Mistri::MCP::OAuth.complete(code: "wrong", **flow.transform_keys(&:to_sym))
      end

      assert_match(/invalid_grant/, error.message)
    end
  end
end
