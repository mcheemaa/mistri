# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
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
    #                                   client_name: "YourApp",
    #                                   redirect_uri: mcp_callback_url)
    #   # persist flow, redirect the user to flow["authorize_url"]
    #
    #   tokens = Mistri::MCP::OAuth.complete(code: params[:code], **persisted)
    #   tokens = Mistri::MCP::OAuth.refresh(**persisted)
    #   # The host verifies callback state before complete.
    #
    # Registration happens as the APPLICATION, never as the harness:
    # client_name has no default because that identity is the host's call.
    # Servers without dynamic registration take client_id:/client_secret:
    # directly and skip it.
    module OAuth # rubocop:disable Metrics/ModuleLength -- one flow shares one validated network chain
      class ConnectionFailure < Error; end
      Response = Data.define(:code, :headers, :body) do
        def [](name) = headers[name.to_s.downcase]
      end
      AUTHORIZE_PARAMETERS = %w[response_type client_id redirect_uri state code_challenge
                                code_challenge_method resource scope].freeze
      MAX_RESPONSE_BYTES = 256 * 1024
      WWW_AUTH_PARAM = /\A([A-Za-z0-9_-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))/
      TOKEN_ERROR_CODES = %w[
        invalid_request invalid_client invalid_grant unauthorized_client
        unsupported_grant_type invalid_scope invalid_target
      ].freeze
      TOKEN_AUTH_METHODS = %w[none client_secret_basic client_secret_post].freeze
      private_constant :ConnectionFailure, :Response, :AUTHORIZE_PARAMETERS,
                       :MAX_RESPONSE_BYTES, :WWW_AUTH_PARAM, :TOKEN_ERROR_CODES,
                       :TOKEN_AUTH_METHODS

      module_function

      # Discover the server's authorization setup, register the application,
      # and build the authorize URL. Returns everything the callback and
      # refresh need: authorize_url, state, code_verifier, client_id,
      # client_secret, token_auth_method, issuer, resource, and redirect_uri.
      # token_endpoint remains informational for compatibility; later
      # operations rediscover it from issuer.
      #
      # With no scope given, the challenge or protected resource's advertised
      # scopes are requested. Extra privileges are always host policy.
      def start(url:, client_name:, redirect_uri:, scope: nil,
                client_id: nil, client_secret: nil, token_auth_method: nil,
                issuer: nil, allow_non_public: nil)
        validate_registration_input(client_id:, client_secret:, token_auth_method:, issuer:)
        resource = canonical(url)
        redirect_uri = Egress.redirect_uri(redirect_uri)
        resource_metadata, challenge_scope = resource_metadata_for(
          resource, allow_non_public: allow_non_public
        )
        authority = authorization_server(resource_metadata, issuer: issuer)
        metadata = server_metadata(authority, allow_non_public: allow_non_public)
        validate_endpoints(metadata, allow_non_public: allow_non_public)
        validate_pkce(metadata)
        resolved_scope = resolve_scope(scope, challenge_scope, resource_metadata)
        registration = register(metadata, client_name:, redirect_uri:, client_id:, client_secret:,
                                          token_auth_method:, allow_non_public:)
        verifier = SecureRandom.urlsafe_base64(48)
        state = SecureRandom.urlsafe_base64(32)
        grant = { client_id: registration["client_id"], redirect_uri: redirect_uri,
                  verifier: verifier, state: state, resource: resource,
                  scope: resolved_scope }
        {
          "authorize_url" => authorize_url(metadata, grant),
          "state" => state, "code_verifier" => verifier,
          "client_id" => registration["client_id"],
          "client_secret" => registration["client_secret"],
          "token_auth_method" => registration["token_endpoint_auth_method"],
          "issuer" => authority,
          "token_endpoint" => metadata.fetch("token_endpoint"),
          "resource" => resource, "redirect_uri" => redirect_uri
        }
      end

      # Exchange the callback's code for tokens.
      def complete(code:, code_verifier:, client_id:, resource:, redirect_uri:, issuer: nil,
                   client_secret: nil, token_auth_method: nil,
                   allow_non_public: nil, **)
        endpoint = discovered_token_endpoint(issuer, allow_non_public: allow_non_public)
        form = { "grant_type" => "authorization_code", "code" => code,
                 "code_verifier" => code_verifier, "client_id" => client_id,
                 "redirect_uri" => Egress.redirect_uri(redirect_uri),
                 "resource" => canonical(resource) }
        token_request(endpoint, form, client_secret, token_auth_method,
                      allow_non_public: allow_non_public)
      end

      # Trade a refresh token for a fresh set; OAuth 2.1 rotates refresh
      # tokens, so persist the returned one.
      def refresh(refresh_token:, client_id:, resource:, issuer: nil, client_secret: nil,
                  token_auth_method: nil, allow_non_public: nil, **)
        endpoint = discovered_token_endpoint(issuer, allow_non_public: allow_non_public)
        form = { "grant_type" => "refresh_token", "refresh_token" => refresh_token,
                 "client_id" => client_id, "resource" => canonical(resource) }
        token_request(endpoint, form, client_secret, token_auth_method,
                      allow_non_public: allow_non_public)
      end

      # -- discovery ---------------------------------------------------------

      # RFC 9728: a 401's WWW-Authenticate names the resource metadata URL;
      # servers that skip the header serve the well-known path.
      def resource_metadata_for(url, allow_non_public: nil)
        challenge = challenge_parameters(url, allow_non_public: allow_non_public)
        candidates = if challenge["resource_metadata"]
                       [[challenge["resource_metadata"], url]]
                     else
                       resource_metadata_candidates(url)
                     end
        candidates.each do |metadata_url, expected_resource|
          document = get_json(metadata_url, allow_non_public: allow_non_public, optional: true)
          next unless document

          validate_resource(document["resource"], expected_resource)
          authorization_servers(document)
          return [document, challenge["scope"]]
        end
        raise Error, "no protected resource metadata for #{Egress.display(URI(url))}"
      end

      def challenge_parameters(url, allow_non_public: nil)
        targets = Egress.targets(url, allow_non_public:, label: "MCP URL")
        request = Net::HTTP::Post.new(targets.first.uri)
        request["Accept"] = "application/json, text/event-stream"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({ jsonrpc: "2.0", id: 0, method: "ping" })
        response = http(targets, request)
        return {} unless response.code.to_i == 401

        parse_www_authenticate(response["WWW-Authenticate"])
      end

      def well_known_resource_urls(url)
        resource_metadata_candidates(url).map(&:first)
      end

      def resource_metadata_candidates(url)
        uri = URI(url)
        path = uri.path == "/" ? "" : uri.path.to_s
        specific = "#{Egress.origin(uri)}/.well-known/oauth-protected-resource#{path}"
        specific = "#{specific}?#{uri.query}" if uri.query
        root = "#{Egress.origin(uri)}/.well-known/oauth-protected-resource"
        [[specific, url], [root, Egress.origin(uri)]].uniq(&:first)
      end

      # RFC 8414 metadata, with the OpenID Connect path as a fallback since
      # large providers often serve only that document.
      def server_metadata(authority, allow_non_public: nil)
        candidates = authorization_metadata_urls(authority)
        candidates.each do |candidate|
          document = get_json(candidate, allow_non_public: allow_non_public, optional: true)
          next unless document

          unless document["issuer"] == authority
            raise Error, "authorization server metadata issuer does not match #{authority}"
          end

          return document
        end
        raise Error, "no authorization server metadata at #{authority}"
      end

      def discovered_token_endpoint(issuer, allow_non_public: nil)
        unless issuer.is_a?(String) && !issuer.empty?
          raise ConfigurationError,
                "issuer: is required; persist flow[\"issuer\"] from OAuth.start"
        end

        metadata = server_metadata(issuer, allow_non_public: allow_non_public)
        endpoint = metadata["token_endpoint"]
        raise Error, "authorization server metadata has no token_endpoint" unless endpoint

        Egress.resolver(endpoint, allow_non_public:, label: "token_endpoint")
        endpoint
      end

      def authorization_metadata_urls(authority)
        uri = Egress.normalize(authority, "authorization server")
        raise Error, "authorization server must not contain a query" if uri.query

        origin = Egress.origin(uri)
        path = uri.path.to_s.chomp("/")
        if path.empty?
          ["#{origin}/.well-known/oauth-authorization-server",
           "#{origin}/.well-known/openid-configuration"]
        else
          ["#{origin}/.well-known/oauth-authorization-server#{path}",
           "#{origin}/.well-known/openid-configuration#{path}",
           "#{origin}#{path}/.well-known/openid-configuration"]
        end
      end

      def authorization_servers(document)
        servers = document["authorization_servers"]
        unless servers.is_a?(Array) && servers.any? &&
               servers.all? { |server| server.is_a?(String) && !server.empty? }
          raise Error, "protected resource metadata names no authorization servers"
        end

        servers.uniq
      end

      # Authorization-server selection is host policy whenever discovery
      # offers a choice. Pre-registered client identities are always bound to
      # the exact issuer supplied when they were provisioned.
      def authorization_server(document, issuer: nil)
        servers = authorization_servers(document)
        if issuer
          return issuer if servers.include?(issuer)

          raise Error, "protected resource metadata does not name the configured issuer"
        end
        return servers.first if servers.one?

        raise ConfigurationError, "multiple authorization servers advertised; pass issuer:"
      end

      # RFC 7591 dynamic registration, as the application. Servers without a
      # registration endpoint require a pre-registered client id. The
      # returned hash keeps the token endpoint auth method the server
      # granted, so token requests authenticate the way it expects.
      def register(metadata, client_name:, redirect_uri:, client_id:, client_secret:,
                   token_auth_method:, allow_non_public:)
        return pre_registered_client(client_id, client_secret, token_auth_method) if client_id

        endpoint = metadata["registration_endpoint"]
        unless endpoint
          raise Error, "the server does not offer dynamic client registration; " \
                       "pass client_id:/client_secret: from a manual registration"
        end

        requested_method = registration_auth_method(metadata)
        registration = post_json(endpoint, {
                                   "client_name" => client_name,
                                   "redirect_uris" => [redirect_uri],
                                   "grant_types" => %w[authorization_code refresh_token],
                                   "response_types" => ["code"],
                                   "token_endpoint_auth_method" => requested_method
                                 }, allow_non_public: allow_non_public)
        result = {
          "client_id" => presence(registration["client_id"]) ||
                         raise(Error, "registration returned no client_id"),
          "client_secret" => presence(registration["client_secret"]),
          "token_endpoint_auth_method" => presence(registration["token_endpoint_auth_method"])
        }
        default_method = result["client_secret"] ? requested_method : "none"
        result["token_endpoint_auth_method"] ||= default_method
        validate_token_auth_method(result["token_endpoint_auth_method"])
        if result["token_endpoint_auth_method"] != "none" && !result["client_secret"]
          raise Error, "registration selected secret authentication without a client_secret"
        end
        if result["token_endpoint_auth_method"] == "none" && result["client_secret"]
          raise Error, "registration returned a client_secret for an unauthenticated client"
        end

        result
      end

      def pre_registered_client(client_id, client_secret, token_auth_method)
        token_auth_method ||= client_secret ? "client_secret_basic" : "none"
        validate_token_auth_method(token_auth_method)
        if token_auth_method != "none" && !client_secret
          raise Error, "#{token_auth_method} requires a client_secret"
        end

        { "client_id" => client_id, "client_secret" => client_secret,
          "token_endpoint_auth_method" => token_auth_method }
      end

      def registration_auth_method(metadata)
        supported = metadata["token_endpoint_auth_methods_supported"]
        supported = ["client_secret_basic"] if supported.nil?
        unless supported.is_a?(Array) && supported.all?(String)
          raise Error, "authorization server token auth methods are malformed"
        end

        preferred = %w[client_secret_basic client_secret_post none]
        preferred.find { |method| supported.include?(method) } ||
          raise(Error, "authorization server offers no supported token auth method")
      end

      def validate_registration_input(client_id:, client_secret:, token_auth_method:, issuer:)
        validate_client_id(client_id) if client_id
        validate_client_secret(client_secret) if client_secret
        validate_issuer_argument(issuer) if issuer
        validate_token_auth_argument(token_auth_method) if token_auth_method
        validate_registration_relationships(client_id, client_secret, token_auth_method, issuer)
      end

      def validate_client_id(client_id)
        return if client_id.is_a?(String) && !client_id.strip.empty?

        raise ConfigurationError, "client_id: must be a non-empty string"
      end

      def validate_client_secret(client_secret)
        return if client_secret.is_a?(String) && !client_secret.empty?

        raise ConfigurationError, "client_secret: must be a non-empty string"
      end

      def validate_issuer_argument(issuer)
        return if issuer.is_a?(String) && !issuer.empty?

        raise ConfigurationError, "issuer: must be a non-empty string"
      end

      def validate_token_auth_argument(token_auth_method)
        return if TOKEN_AUTH_METHODS.include?(token_auth_method)

        raise ConfigurationError,
              "unsupported token endpoint authentication method #{token_auth_method.inspect}"
      end

      def validate_registration_relationships(client_id, client_secret, token_auth_method, issuer)
        if client_secret && !client_id
          raise ConfigurationError, "client_secret: requires client_id:"
        end
        if token_auth_method && !client_id
          raise ConfigurationError, "token_auth_method: requires client_id:"
        end
        if client_id && !issuer
          raise ConfigurationError,
                "issuer: is required for a pre-registered client_id"
        end
        secret_methods = %w[client_secret_basic client_secret_post]
        if client_id && secret_methods.include?(token_auth_method) && !client_secret
          raise ConfigurationError, "#{token_auth_method} requires a client_secret"
        end
        return unless client_secret && token_auth_method == "none"

        raise ConfigurationError, "token_auth_method: none cannot be paired with client_secret:"
      end

      # Explicit host policy wins; otherwise the 401 challenge and then the
      # protected resource metadata define the least-privilege request.
      def resolve_scope(scope, challenge_scope, resource_metadata)
        challenged = challenge_scope.to_s.split.uniq
        if scope
          requested = scope.to_s.split.uniq
          missing = challenged - requested
          unless missing.empty?
            raise ConfigurationError,
                  "scope: must include every scope required by the MCP challenge"
          end

          return requested.empty? ? nil : requested.join(" ")
        end
        return challenged.join(" ") unless challenged.empty?

        supported = resource_metadata["scopes_supported"]
        return nil if supported.nil?
        unless supported.is_a?(Array) && supported.all?(String)
          raise Error, "protected resource scopes_supported is malformed"
        end

        supported.empty? ? nil : supported.uniq.join(" ")
      end

      def validate_endpoints(metadata, allow_non_public: nil)
        %w[authorization_endpoint token_endpoint].each do |required|
          raise Error, "authorization server metadata has no #{required}" unless metadata[required]
        end
        %w[authorization_endpoint token_endpoint registration_endpoint].each do |key|
          value = metadata[key] or next
          Egress.target(value, allow_non_public:, label: key)
        end
      end

      def validate_pkce(metadata)
        methods = metadata["code_challenge_methods_supported"]
        return if methods.is_a?(Array) && methods.include?("S256")

        raise Error, "authorization server does not advertise S256 PKCE support"
      end

      def validate_token_auth_method(method)
        return if TOKEN_AUTH_METHODS.include?(method)

        raise Error, "unsupported token endpoint authentication method"
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
        existing = URI.decode_www_form(endpoint.query.to_s)
        existing.reject! { |key, _value| AUTHORIZE_PARAMETERS.include?(key) }
        endpoint.query = URI.encode_www_form(existing + params.to_a)
        endpoint.to_s
      end

      # -- plumbing ----------------------------------------------------------

      # RFC 8707 canonical form: lowercase scheme and host, with no default
      # port or semantically empty root path.
      def canonical(url)
        Egress.normalize(url, "resource").to_s
      end

      def token_request(endpoint, form, client_secret, auth_method = nil, allow_non_public: nil)
        # 0.5.0 persisted no method and sent the secret in the form. New flows
        # always persist an explicit method; keep old connected rows usable.
        auth_method ||= client_secret ? "client_secret_post" : "none"
        validate_token_auth_method(auth_method)
        form, credentials = token_authentication(form, client_secret, auth_method)
        payload = post_form(endpoint, form, basic_auth: credentials,
                                            allow_non_public: allow_non_public)
        validate_token_response(payload)

        expires_in = payload["expires_in"]
        {
          "access_token" => payload["access_token"],
          "refresh_token" => payload["refresh_token"],
          "scope" => payload["scope"],
          "expires_at" => expires_in ? Time.now.utc + expires_in.to_i : nil
        }
      end

      def token_authentication(form, client_secret, auth_method)
        if auth_method == "none" && client_secret
          raise Error, "token_endpoint_auth_method none cannot use a client_secret"
        end

        credentials = nil
        case auth_method
        when "client_secret_basic"
          raise Error, "client_secret_basic requires a client_secret" unless client_secret

          credentials = [form["client_id"], client_secret].map do |part|
            URI.encode_www_form_component(part)
          end
        when "client_secret_post"
          raise Error, "client_secret_post requires a client_secret" unless client_secret

          form = form.merge("client_secret" => client_secret)
        end

        [form, credentials]
      end

      def validate_token_response(payload)
        token_type = payload["token_type"]
        unless token_type.is_a?(String) && token_type.casecmp?("Bearer")
          raise Error, "token endpoint returned unsupported token_type"
        end

        access_token = payload["access_token"]
        return if access_token.is_a?(String) && !access_token.strip.empty?

        raise Error, "token endpoint returned no access_token"
      end

      def get_json(url, allow_non_public: nil, optional: false)
        targets = Egress.targets(url, allow_non_public:, label: "metadata URL")
        location = Egress.display(targets.first.uri)
        request = Net::HTTP::Get.new(targets.first.uri)
        request["Accept"] = "application/json"
        response = http(targets, request)
        return nil if optional && response.code.to_i != 200
        raise Error, "GET #{location} answered #{response.code}" unless response.code.to_i == 200

        object = JSON.parse(response.body)
        raise Error, "GET #{location} did not return a JSON object" unless object.is_a?(Hash)

        object
      rescue ConnectionFailure
        return nil if optional

        raise
      rescue JSON::ParserError
        raise Error, "GET #{location} returned invalid JSON"
      end

      def post_json(url, body, allow_non_public: nil)
        targets = Egress.targets(url, allow_non_public:, label: "registration_endpoint")
        location = Egress.display(targets.first.uri)
        request = Net::HTTP::Post.new(targets.first.uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate(body)
        response = http(targets, request)
        unless %w[200 201].include?(response.code)
          raise Error, "POST #{location} answered #{response.code}"
        end

        object = JSON.parse(response.body)
        raise Error, "registration endpoint did not return a JSON object" unless object.is_a?(Hash)

        object
      rescue JSON::ParserError
        raise Error, "registration endpoint returned invalid JSON"
      end

      def post_form(url, form, basic_auth: nil, allow_non_public: nil)
        targets = Egress.targets(url, allow_non_public:, label: "token_endpoint")
        request = Net::HTTP::Post.new(targets.first.uri)
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request["Accept"] = "application/json"
        request.basic_auth(*basic_auth) if basic_auth
        request.body = URI.encode_www_form(form)
        response = http(targets, request)
        payload = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          raise Error, "token endpoint returned invalid JSON" if response.code.to_i == 200

          {}
        end
        raise Error, "token endpoint did not return a JSON object" unless payload.is_a?(Hash)

        unless response.code.to_i == 200
          reason = payload["error"]
          reason = nil unless TOKEN_ERROR_CODES.include?(reason)
          detail = reason ? ": #{reason}" : ""
          raise Error, "token request failed (#{response.code})#{detail}"
        end
        payload
      end

      def http(targets, request)
        request["Accept-Encoding"] = "identity"
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
        targets.each do |target|
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break unless remaining.positive?

          connection = oauth_connection(target, open_timeout: remaining)
          begin
            connection.start
          rescue IOError, SocketError, SystemCallError, Timeout::Error,
                 Net::HTTPBadResponse, OpenSSL::SSL::SSLError
            next
          end

          begin
            return bounded_response(connection, request)
          rescue IOError, SocketError, SystemCallError, Timeout::Error,
                 Net::HTTPBadResponse, OpenSSL::SSL::SSLError
            raise ConnectionFailure, "OAuth connection failed"
          ensure
            finish_connection(connection)
          end
        end
        raise ConnectionFailure, "OAuth connection failed"
      end

      def oauth_connection(target, open_timeout:)
        Net::HTTP.new(target.uri.hostname, target.uri.port, nil).tap do |connection|
          connection.ipaddr = target.address
          connection.use_ssl = target.uri.scheme == "https"
          connection.open_timeout = open_timeout
          connection.read_timeout = 30
          connection.max_retries = 0
        end
      end

      def bounded_response(connection, request)
        result = nil
        connection.request(request) do |response|
          body = +""
          response.read_body do |chunk|
            if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
              raise Error, "OAuth response exceeded #{MAX_RESPONSE_BYTES} bytes"
            end

            body << chunk
          end
          headers = response.to_hash.transform_values { |values| values.join(", ") }
          result = Response.new(code: response.code, headers: headers, body: body)
        end
        result
      end

      def finish_connection(connection)
        connection.finish if connection.started?
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end

      def validate_resource(candidate, expected)
        raise Error, "protected resource metadata has no resource" unless candidate.is_a?(String)

        resource = canonical(candidate)
        return if resource == canonical(expected)

        raise Error,
              "protected resource metadata resource does not match " \
              "#{Egress.display(URI(expected))}"
      end

      def parse_www_authenticate(header)
        match = header.to_s.match(/(?:\A|,)\s*Bearer(?:\s+|\z)/i)
        return {} unless match

        cursor = match.end(0)
        params = {}
        while cursor < header.length
          rest = header[cursor..].sub(/\A\s*,?\s*/, "")
          pair = rest.match(WWW_AUTH_PARAM)
          break unless pair

          params[pair[1].downcase] = pair[2] ? pair[2].gsub(/\\(.)/, '\\1') : pair[3]
          cursor = header.length - rest.length + pair.end(0)
        end
        params
      end
    end # rubocop:enable Metrics/ModuleLength
  end
end
