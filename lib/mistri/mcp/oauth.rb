# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "securerandom"
require "uri"

module Mistri
  module MCP
    # The OAuth 2.1 subset the MCP spec requires of clients, as three
    # storage-agnostic services a host calls from anywhere: a controller, a
    # GraphQL mutation, a job. Each returns a string-keyed hash ready to
    # persist on the host's own connection record.
    #
    #   flow = Mistri::MCP::OAuth.start(url: params[:url],
    #                                   client_name: "Sendoso",
    #                                   redirect_uri: mcp_callback_url)
    #   # persist flow, redirect the user to flow["authorize_url"]
    #
    #   tokens = Mistri::MCP::OAuth.complete(code: params[:code], **persisted)
    #   tokens = Mistri::MCP::OAuth.refresh(**persisted)
    #
    # Registration happens as the APPLICATION, never as the harness:
    # client_name has no default because that identity is the host's call.
    # Servers without dynamic registration take client_id:/client_secret:
    # directly and skip it.
    module OAuth
      module_function

      # Discover the server's authorization setup, register the application,
      # and build the authorize URL. Returns everything the callback and
      # refresh need: authorize_url, state, code_verifier, client_id,
      # client_secret, token_endpoint, resource, redirect_uri.
      def start(url:, client_name:, redirect_uri:, scope: nil,
                client_id: nil, client_secret: nil)
        resource = canonical(url)
        authority = authorization_server_for(url)
        metadata = server_metadata(authority)
        client_id, client_secret = register(metadata, client_name, redirect_uri,
                                            client_id, client_secret)
        verifier = SecureRandom.urlsafe_base64(48)
        state = SecureRandom.urlsafe_base64(24)
        grant = { client_id: client_id, redirect_uri: redirect_uri, verifier: verifier,
                  state: state, resource: resource, scope: scope }
        {
          "authorize_url" => authorize_url(metadata, grant),
          "state" => state, "code_verifier" => verifier,
          "client_id" => client_id, "client_secret" => client_secret,
          "token_endpoint" => metadata.fetch("token_endpoint"),
          "resource" => resource, "redirect_uri" => redirect_uri
        }
      end

      # Exchange the callback's code for tokens.
      def complete(code:, code_verifier:, client_id:, token_endpoint:, resource:,
                   redirect_uri:, client_secret: nil, **)
        form = { "grant_type" => "authorization_code", "code" => code,
                 "code_verifier" => code_verifier, "client_id" => client_id,
                 "redirect_uri" => redirect_uri, "resource" => resource }
        token_request(token_endpoint, form, client_secret)
      end

      # Trade a refresh token for a fresh set; OAuth 2.1 rotates refresh
      # tokens, so persist the returned one.
      def refresh(refresh_token:, client_id:, token_endpoint:, resource:,
                  client_secret: nil, **)
        form = { "grant_type" => "refresh_token", "refresh_token" => refresh_token,
                 "client_id" => client_id, "resource" => resource }
        token_request(token_endpoint, form, client_secret)
      end

      # -- discovery ---------------------------------------------------------

      # RFC 9728: a 401's WWW-Authenticate names the resource metadata URL;
      # servers that skip the header serve the well-known path.
      def authorization_server_for(url)
        metadata_url = challenge_metadata_url(url) || well_known_resource_url(url)
        document = get_json(metadata_url)
        servers = Array(document["authorization_servers"])
        raise Error, "#{metadata_url} names no authorization servers" if servers.empty?

        servers.first
      end

      def challenge_metadata_url(url)
        uri = URI(url)
        response = http(uri) do |connection|
          request = Net::HTTP::Post.new(uri)
          request["Accept"] = "application/json, text/event-stream"
          request["Content-Type"] = "application/json"
          request.body = JSON.generate({ jsonrpc: "2.0", id: 0, method: "ping" })
          connection.request(request)
        end
        challenge = response["WWW-Authenticate"].to_s
        challenge[/resource_metadata="([^"]+)"/, 1]
      end

      def well_known_resource_url(url)
        uri = URI(url)
        path = uri.path.chomp("/")
        origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        "#{origin}/.well-known/oauth-protected-resource#{path unless path.empty?}"
      end

      # RFC 8414 metadata, with the OpenID Connect path as a fallback since
      # large providers often serve only that document.
      def server_metadata(authority)
        uri = URI(authority)
        origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        path = uri.path.chomp("/")
        candidates = ["#{origin}/.well-known/oauth-authorization-server#{path unless path.empty?}",
                      "#{origin}#{path}/.well-known/openid-configuration"]
        candidates.each do |candidate|
          document = try_json(candidate)
          return document if document&.key?("token_endpoint")
        end
        raise Error, "no authorization server metadata at #{authority}"
      end

      # RFC 7591 dynamic registration, as the application. Servers without a
      # registration endpoint require a pre-registered client id.
      def register(metadata, client_name, redirect_uri, client_id, client_secret)
        return [client_id, client_secret] if client_id

        endpoint = metadata["registration_endpoint"]
        unless endpoint
          raise Error, "the server does not offer dynamic client registration; " \
                       "pass client_id:/client_secret: from a manual registration"
        end

        registration = post_json(endpoint, {
                                   "client_name" => client_name,
                                   "redirect_uris" => [redirect_uri],
                                   "grant_types" => %w[authorization_code refresh_token],
                                   "response_types" => ["code"]
                                 })
        [registration.fetch("client_id"), registration["client_secret"]]
      end

      def authorize_url(metadata, grant)
        challenge = Digest::SHA256.base64digest(grant[:verifier]).tr("+/", "-_").delete("=")
        params = { "response_type" => "code", "client_id" => grant[:client_id],
                   "redirect_uri" => grant[:redirect_uri], "state" => grant[:state],
                   "code_challenge" => challenge, "code_challenge_method" => "S256",
                   "resource" => grant[:resource] }
        params["scope"] = grant[:scope] if grant[:scope]
        endpoint = URI(metadata.fetch("authorization_endpoint"))
        endpoint.query = [endpoint.query, URI.encode_www_form(params)].compact.join("&")
        endpoint.to_s
      end

      # -- plumbing ----------------------------------------------------------

      def canonical(url)
        uri = URI(url)
        uri.fragment = nil
        uri.to_s
      end

      def token_request(endpoint, form, client_secret)
        form = form.merge("client_secret" => client_secret) if client_secret
        payload = post_form(endpoint, form)
        expires_in = payload["expires_in"]
        {
          "access_token" => payload.fetch("access_token"),
          "refresh_token" => payload["refresh_token"],
          "scope" => payload["scope"],
          "expires_at" => expires_in ? Time.now.utc + expires_in.to_i : nil
        }
      end

      def get_json(url)
        uri = URI(url)
        response = http(uri) { |connection| connection.request(Net::HTTP::Get.new(uri)) }
        raise Error, "GET #{url} answered #{response.code}" unless response.code.to_i == 200

        JSON.parse(response.body)
      end

      def try_json(url)
        get_json(url)
      rescue Error, JSON::ParserError
        nil
      end

      def post_json(url, body)
        uri = URI(url)
        response = http(uri) do |connection|
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
          connection.request(request)
        end
        unless %w[200 201].include?(response.code)
          raise Error, "POST #{url} answered #{response.code}: #{response.body.to_s[0, 200]}"
        end

        JSON.parse(response.body)
      end

      def post_form(url, form)
        uri = URI(url)
        response = http(uri) do |connection|
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request["Accept"] = "application/json"
          request.body = URI.encode_www_form(form)
          connection.request(request)
        end
        payload = begin
          JSON.parse(response.body)
        rescue StandardError
          {}
        end
        unless response.code.to_i == 200
          reason = payload["error_description"] || payload["error"] || response.body.to_s[0, 200]
          raise Error, "token request failed (#{response.code}): #{reason}"
        end

        payload
      end

      def http(uri, &)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: 15, read_timeout: 30, &)
      end
    end
  end
end
