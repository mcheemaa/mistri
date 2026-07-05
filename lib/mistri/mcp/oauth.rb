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
      # client_secret, token_auth_method, token_endpoint, resource,
      # redirect_uri.
      #
      # With no scope given, the server's advertised scopes_supported are
      # requested, and offline_access rides along when the authorization
      # server supports it, which is what earns a refresh token from
      # providers that require it.
      def start(url:, client_name:, redirect_uri:, scope: nil,
                client_id: nil, client_secret: nil)
        resource = canonical(url)
        resource_metadata = resource_metadata_for(url)
        metadata = server_metadata(Array(resource_metadata["authorization_servers"]).first)
        validate_endpoints(metadata)
        registration = register(metadata, client_name, redirect_uri, client_id, client_secret)
        verifier = SecureRandom.urlsafe_base64(48)
        state = SecureRandom.urlsafe_base64(32)
        grant = { client_id: registration["client_id"], redirect_uri: redirect_uri,
                  verifier: verifier, state: state, resource: resource,
                  scope: resolve_scope(scope, resource_metadata, metadata) }
        {
          "authorize_url" => authorize_url(metadata, grant),
          "state" => state, "code_verifier" => verifier,
          "client_id" => registration["client_id"],
          "client_secret" => registration["client_secret"],
          "token_auth_method" => registration["token_endpoint_auth_method"],
          "token_endpoint" => metadata.fetch("token_endpoint"),
          "resource" => resource, "redirect_uri" => redirect_uri
        }
      end

      # Exchange the callback's code for tokens.
      def complete(code:, code_verifier:, client_id:, token_endpoint:, resource:,
                   redirect_uri:, client_secret: nil, token_auth_method: nil, **)
        form = { "grant_type" => "authorization_code", "code" => code,
                 "code_verifier" => code_verifier, "client_id" => client_id,
                 "redirect_uri" => redirect_uri, "resource" => resource }
        token_request(token_endpoint, form, client_secret, token_auth_method)
      end

      # Trade a refresh token for a fresh set; OAuth 2.1 rotates refresh
      # tokens, so persist the returned one.
      def refresh(refresh_token:, client_id:, token_endpoint:, resource:,
                  client_secret: nil, token_auth_method: nil, **)
        form = { "grant_type" => "refresh_token", "refresh_token" => refresh_token,
                 "client_id" => client_id, "resource" => resource }
        token_request(token_endpoint, form, client_secret, token_auth_method)
      end

      # -- discovery ---------------------------------------------------------

      # RFC 9728: a 401's WWW-Authenticate names the resource metadata URL;
      # servers that skip the header serve the well-known path.
      def resource_metadata_for(url)
        metadata_url = challenge_metadata_url(url) || well_known_resource_url(url)
        document = get_json(metadata_url)
        if Array(document["authorization_servers"]).empty?
          raise Error, "#{metadata_url} names no authorization servers"
        end

        document
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
        challenge[/resource_metadata="([^"]+)"/i, 1]
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
      # registration endpoint require a pre-registered client id. The
      # returned hash keeps the token endpoint auth method the server
      # granted, so token requests authenticate the way it expects.
      def register(metadata, client_name, redirect_uri, client_id, client_secret)
        return { "client_id" => client_id, "client_secret" => client_secret } if client_id

        endpoint = metadata["registration_endpoint"]
        unless endpoint
          raise Error, "the server does not offer dynamic client registration; " \
                       "pass client_id:/client_secret: from a manual registration"
        end

        registration = post_json(endpoint, {
                                   "client_name" => client_name,
                                   "redirect_uris" => [redirect_uri],
                                   "grant_types" => %w[authorization_code refresh_token],
                                   "response_types" => ["code"],
                                   "token_endpoint_auth_method" => "client_secret_post"
                                 })
        {
          "client_id" => presence(registration["client_id"]) ||
            raise(Error, "registration returned no client_id"),
          "client_secret" => presence(registration["client_secret"]),
          "token_endpoint_auth_method" => presence(registration["token_endpoint_auth_method"])
        }
      end

      # No scope given: request what the resource advertises, and add
      # offline_access when the authorization server supports it (that is
      # what earns a refresh token from providers that require it). An
      # unsupported offline_access is stripped rather than sent blind.
      def resolve_scope(scope, resource_metadata, metadata)
        scopes = scope.to_s.split
        scopes = Array(resource_metadata["scopes_supported"]) if scopes.empty?
        supported = Array(metadata["scopes_supported"])
        if supported.include?("offline_access")
          scopes |= ["offline_access"]
        else
          scopes -= ["offline_access"]
        end
        scopes.empty? ? nil : scopes.join(" ")
      end

      # The spec requires authorization server endpoints over HTTPS;
      # loopback stays allowed for development.
      def validate_endpoints(metadata)
        %w[authorization_endpoint token_endpoint registration_endpoint].each do |key|
          value = metadata[key] or next
          uri = URI(value)
          next if uri.scheme == "https" || %w[localhost 127.0.0.1 ::1].include?(uri.host)

          raise Error, "#{key} #{value} is not HTTPS"
        end
      end

      def presence(value)
        value.to_s.strip.empty? ? nil : value
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

      # RFC 8707 canonical form: lowercase scheme and host, no fragment.
      def canonical(url)
        uri = URI(url)
        uri.fragment = nil
        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase if uri.host
        uri.to_s
      end

      def token_request(endpoint, form, client_secret, auth_method = nil)
        basic = client_secret && auth_method == "client_secret_basic"
        form = form.merge("client_secret" => client_secret) if client_secret && !basic
        credentials = basic ? [form["client_id"], client_secret] : nil
        payload = post_form(endpoint, form, basic_auth: credentials)
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

      def post_form(url, form, basic_auth: nil)
        uri = URI(url)
        response = http(uri) do |connection|
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request["Accept"] = "application/json"
          request.basic_auth(*basic_auth) if basic_auth
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
