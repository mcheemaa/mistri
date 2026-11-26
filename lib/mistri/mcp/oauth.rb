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
    #   tokens = Mistri::MCP::OAuth.complete(code: params[:code], iss: params[:iss], **persisted)
    #   tokens = Mistri::MCP::OAuth.refresh(**persisted)
    #   # The host verifies callback state before complete.
    #
    # Registration happens as the APPLICATION, never as the harness:
    # client_name has no default because that identity is the host's call.
    # Servers without dynamic registration take client_id:/client_secret:
    # directly and skip it.
    module OAuth # rubocop:disable Metrics/ModuleLength -- one flow shares one validated network chain
      class ConnectionFailure < Error; end

      # The token endpoint refused a request. reason is the code it gave when
      # that is one of the standard ones, and status its HTTP status.
      class TokenError < Error
        attr_reader :status, :reason

        def initialize(message = nil, status: nil, reason: nil)
          @status = status
          @reason = reason
          super(message)
        end
      end

      # The grant is spent or revoked, so the person signs in again.
      class InvalidGrantError < TokenError; end

      # The server does not name the issuer a client is registered with: its
      # authorization server changed, or the issuer was written down wrong.
      class IssuerChanged < Error; end

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
      # Stands for a callback whose iss the host did not hand over.
      UNCHECKED = Object.new.freeze
      private_constant :ConnectionFailure, :Response, :AUTHORIZE_PARAMETERS,
                       :MAX_RESPONSE_BYTES, :WWW_AUTH_PARAM, :TOKEN_ERROR_CODES,
                       :TOKEN_AUTH_METHODS, :UNCHECKED

      module_function

      # Discover the server's authorization setup, register the application,
      # and build the authorize URL. Returns everything the callback and
      # refresh need: authorize_url, state, code_verifier, client_id,
      # client_secret, token_auth_method, issuer, resource, and redirect_uri.
      # scope is the scope asked for, which is what was granted when the
      # token response names none.
      # token_endpoint remains informational for compatibility; later
      # operations rediscover it from issuer.
      #
      # With no scope given, the challenge or protected resource's advertised
      # scopes are requested. Extra privileges are always host policy, and
      # offline_access: true is one: the scope is added when the authorization
      # server lists it.
      #
      # client_metadata_url: is the address of the application's client ID
      # metadata document. A server that takes one gets it as the client ID,
      # and nothing is registered. tolerant: true accepts what exact discovery
      # refuses; see docs/mcp.md.
      def start(url:, client_name:, redirect_uri:, scope: nil,
                client_id: nil, client_secret: nil, token_auth_method: nil,
                issuer: nil, allow_non_public: nil, client_metadata_url: nil,
                offline_access: false, tolerant: false)
        validate_registration_input(client_id:, client_secret:, token_auth_method:, issuer:)
        validate_client_metadata_url(client_metadata_url) if client_metadata_url
        redirect_uri = Egress.redirect_uri(redirect_uri)
        found = discovery(url, issuer:, scope:, allow_non_public:, tolerant:)
        metadata = found["server_metadata"]
        registration = register(metadata, client_name:, redirect_uri:, client_id:, client_secret:,
                                          token_auth_method:, allow_non_public:,
                                          client_metadata_url:)
        verifier = SecureRandom.urlsafe_base64(48)
        state = SecureRandom.urlsafe_base64(32)
        requested = offline_access ? with_offline_access(found["scope"], metadata) : found["scope"]
        grant = { client_id: registration["client_id"], redirect_uri: redirect_uri,
                  verifier: verifier, state: state, resource: found["resource"],
                  scope: requested }
        {
          "authorize_url" => authorize_url(metadata, grant),
          "state" => state, "code_verifier" => verifier,
          "client_id" => registration["client_id"],
          "client_secret" => registration["client_secret"],
          "token_auth_method" => registration["token_endpoint_auth_method"],
          "issuer" => found["issuer"],
          "token_endpoint" => metadata.fetch("token_endpoint"),
          "resource" => found["resource"], "redirect_uri" => redirect_uri,
          "scope" => requested
        }
      end

      # How a server signs people in, read and nothing registered: the
      # resource tokens are asked for, the issuer, the scope a sign-in would
      # ask for, and the two metadata documents as the servers publish them.
      def discover(url:, issuer: nil, allow_non_public: nil, tolerant: false)
        validate_issuer_argument(issuer) if issuer
        discovery(url, issuer:, scope: nil, allow_non_public:, tolerant:)
      end

      # Exchange the callback's code for tokens. iss: is the iss parameter of
      # the callback, nil when it had none. A callback that names another
      # issuer, or names none where the authorization server says it sends
      # one, is refused before the code is sent anywhere (RFC 9207). A host
      # that leaves the keyword out gets no such check.
      def complete(code:, code_verifier:, client_id:, resource:, redirect_uri:, issuer: nil,
                   client_secret: nil, token_auth_method: nil,
                   allow_non_public: nil, iss: UNCHECKED, tolerant: false, **)
        metadata = bound_metadata(issuer, allow_non_public:, tolerant:, resource:)
        verify_response_issuer(iss, metadata)
        endpoint = checked_token_endpoint(metadata, allow_non_public:)
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
                  token_auth_method: nil, allow_non_public: nil, tolerant: false, **)
        endpoint = discovered_token_endpoint(issuer, allow_non_public:, tolerant:, resource:)
        form = { "grant_type" => "refresh_token", "refresh_token" => refresh_token,
                 "client_id" => client_id, "resource" => canonical(resource) }
        token_request(endpoint, form, client_secret, token_auth_method,
                      allow_non_public: allow_non_public)
      end

      # Ends a token at its authorization server (RFC 7009). Returns false
      # for a server that names no revocation endpoint.
      def revoke(token:, client_id:, issuer: nil, client_secret: nil, token_auth_method: nil,
                 allow_non_public: nil, tolerant: false, resource: nil, **)
        metadata = bound_metadata(issuer, allow_non_public:, tolerant:, resource:)
        endpoint = metadata["revocation_endpoint"]
        return false unless endpoint

        method = stored_auth_method(client_secret, token_auth_method)
        form, credentials = token_authentication({ "token" => token, "client_id" => client_id },
                                                 client_secret, method)
        response = post(endpoint, form, basic_auth: credentials, allow_non_public:,
                                        label: "revocation_endpoint")
        return true if response.code.to_i == 200

        raise TokenError.new("token revocation failed (#{response.code})",
                             status: response.code.to_i)
      end

      # The Bearer challenge of a refusal: "error", "scope", "resource_metadata"
      # and whatever else the server sent. Empty when it sent none.
      def challenge(error)
        parse_www_authenticate(error.respond_to?(:challenge) ? error.challenge : nil)
      end

      # The scope to sign in again with after a 403 that asks for more: what
      # was granted and what the challenge asks for, each once. nil when the
      # challenge names none, so the sign-in asks for its default.
      def step_up_scope(granted, challenged)
        return nil if challenged.to_s.strip.empty?

        [granted, challenged].flat_map { |scope| scope.to_s.split }.uniq.join(" ")
      end

      # -- discovery ---------------------------------------------------------

      # The steps before a registration. Without a resource document, which
      # only tolerant discovery goes on from, the server's origin stands for
      # the authorization server, as the 2025-03-26 revision had it.
      def discovery(url, issuer:, scope:, allow_non_public:, tolerant:)
        resource = canonical(url)
        document, challenge_scope = resource_metadata_for(resource, allow_non_public:, tolerant:)
        authority = if document
                      authorization_server(document, issuer:, tolerant:)
                    else
                      origin_as_issuer(resource, issuer)
                    end
        metadata = server_metadata(authority, allow_non_public:, tolerant:, defaults: document.nil?)
        validate_endpoints(metadata, allow_non_public: allow_non_public)
        validate_pkce(metadata)
        resource = canonical(document["resource"]) if tolerant && document
        { "resource" => resource, "issuer" => metadata["issuer"],
          "scope" => resolve_scope(scope, challenge_scope, document || {}),
          "resource_metadata" => document, "server_metadata" => metadata }
      end

      # A client that was registered with another issuer is not handed to the
      # origin of a server that names no authorization server.
      def origin_as_issuer(resource, issuer)
        origin = Egress.origin(URI(resource))
        return origin if issuer.nil? || same_issuer?(origin, issuer)

        raise IssuerChanged, "the server's origin stands for its authorization server, " \
                             "and it is not the configured issuer"
      end

      # RFC 9728: a 401's WWW-Authenticate names the resource metadata URL;
      # servers that skip the header serve the well-known path.
      #
      # Tolerant discovery also looks at the well-known paths when the address
      # a challenge names holds nothing, and goes on with no document only for
      # a server that did refuse the request: one that takes it has no sign-in.
      def resource_metadata_for(url, allow_non_public: nil, tolerant: false)
        refusal = unauthorized(url, allow_non_public:)
        challenge = refusal ? parse_www_authenticate(refusal["WWW-Authenticate"]) : {}
        named = challenge["resource_metadata"]
        candidates = named ? [[named, url]] : resource_metadata_candidates(url)
        candidates += resource_metadata_candidates(url) if named && tolerant
        missed = tolerant ? [] : nil
        candidates.each do |metadata_url, expected_resource|
          document = get_json(metadata_url, allow_non_public:, optional: true, missed:)
          next unless document

          validate_resource(document["resource"], expected_resource, url, tolerant:)
          authorization_servers(document)
          return [document, challenge["scope"]]
        end
        return [nil, challenge["scope"]] if tolerant && refusal && unpublished?(missed)

        raise Error, "no protected resource metadata for #{Egress.display(URI(url))}"
      end

      def challenge_parameters(url, allow_non_public: nil)
        refusal = unauthorized(url, allow_non_public:)
        refusal ? parse_www_authenticate(refusal["WWW-Authenticate"]) : {}
      end

      # The server's answer to a request that carries no token, when it is a
      # 401. nil for a server that takes the request.
      def unauthorized(url, allow_non_public: nil)
        targets = Egress.targets(url, allow_non_public:, label: "MCP URL")
        request = Net::HTTP::Post.new(targets.first.uri)
        request["Accept"] = "application/json, text/event-stream"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({ jsonrpc: "2.0", id: 0, method: "ping" })
        response = http(targets, request)
        response if response.code.to_i == 401
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
      # defaults: is for the server of the 2025-03-26 revision, which is its
      # own authorization server and may publish no metadata at all.
      def server_metadata(authority, allow_non_public: nil, tolerant: false, defaults: false)
        candidates = authorization_metadata_urls(authority)
        missed = tolerant ? [] : nil
        candidates.each do |candidate|
          document = get_json(candidate, allow_non_public:, optional: true, missed:)
          next unless document

          named = document["issuer"]
          alike = same_issuer?(named, authority)
          unless tolerant ? alike : named == authority
            raise Error, "authorization server metadata issuer does not match #{authority}" \
                         "#{tolerable("it differs by one trailing slash") if alike}"
          end

          return document
        end
        return default_metadata(authority) if tolerant && defaults && unpublished?(missed)

        raise Error, "no authorization server metadata at #{authority}"
      end

      def discovered_token_endpoint(issuer, allow_non_public: nil, tolerant: false, resource: nil)
        checked_token_endpoint(bound_metadata(issuer, allow_non_public:, tolerant:, resource:),
                               allow_non_public:)
      end

      # The metadata of the issuer a flow was started with. Every later
      # request of the flow goes to an endpoint it names, and to no other. An
      # issuer that is the origin of resource: may be a server of 2025-03-26.
      def bound_metadata(issuer, allow_non_public: nil, tolerant: false, resource: nil)
        unless issuer.is_a?(String) && !issuer.empty?
          raise ConfigurationError,
                "issuer: is required; persist flow[\"issuer\"] from OAuth.start"
        end

        own = tolerant && resource && same_issuer?(issuer, Egress.origin(URI(canonical(resource))))
        server_metadata(issuer, allow_non_public:, tolerant:, defaults: own)
      end

      def checked_token_endpoint(metadata, allow_non_public: nil)
        endpoint = metadata["token_endpoint"]
        raise Error, "authorization server metadata has no token_endpoint" unless endpoint

        Egress.resolver(endpoint, allow_non_public:, label: "token_endpoint")
        endpoint
      end

      # RFC 9207: a code goes only to the server its response names.
      def verify_response_issuer(iss, metadata)
        return if iss.equal?(UNCHECKED)

        if iss.nil? || iss == ""
          return unless metadata["authorization_response_iss_parameter_supported"] == true

          raise Error, "the authorization response has no iss, which its server says it sends"
        end
        return if iss == metadata["issuer"]

        raise Error, "the authorization response's iss is not the issuer of this sign-in"
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
      def authorization_server(document, issuer: nil, tolerant: false)
        servers = authorization_servers(document)
        if issuer
          alike = servers.select { |server| same_issuer?(server, issuer) }
          named = tolerant ? alike.first : alike.find { |server| server == issuer }
          return named if named

          slash = tolerable("one it names differs by one trailing slash") unless alike.empty?
          raise IssuerChanged,
                "protected resource metadata does not name the configured issuer#{slash}"
        end
        return servers.first if servers.one?

        raise ConfigurationError, "multiple authorization servers advertised; pass issuer:"
      end

      # RFC 7591 dynamic registration, as the application. Servers without a
      # registration endpoint require a pre-registered client id. The
      # returned hash keeps the token endpoint auth method the server
      # granted, so token requests authenticate the way it expects.
      def register(metadata, client_name:, redirect_uri:, client_id:, client_secret:,
                   token_auth_method:, allow_non_public:, client_metadata_url: nil)
        return pre_registered_client(client_id, client_secret, token_auth_method) if client_id
        if client_metadata_url && metadata["client_id_metadata_document_supported"] == true
          return { "client_id" => client_metadata_url, "client_secret" => nil,
                   "token_endpoint_auth_method" => "none" }
        end

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
                                   "token_endpoint_auth_method" => requested_method,
                                   "application_type" => application_type(redirect_uri)
                                 }, allow_non_public: allow_non_public)
        result = registered(registration, requested_method)
        validate_token_auth_method(result["token_endpoint_auth_method"])
        if result["token_endpoint_auth_method"] != "none" && !result["client_secret"]
          raise Error, "registration selected secret authentication without a client_secret"
        end
        if result["token_endpoint_auth_method"] == "none" && result["client_secret"]
          raise Error, "registration returned a client_secret for an unauthenticated client"
        end

        result
      end

      # A server may hand out a secret and name no method. The method is then
      # the one asked for, and with none asked for the secret is not kept,
      # because the client would never present it.
      def registered(registration, requested_method)
        named = presence(registration["token_endpoint_auth_method"])
        secret = presence(registration["client_secret"])
        method = named || (secret ? requested_method : "none")
        secret = nil if named.nil? && method == "none"
        client_id = presence(registration["client_id"])
        raise Error, "registration returned no client_id" unless client_id

        { "client_id" => client_id, "client_secret" => secret,
          "token_endpoint_auth_method" => method }
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

      # offline_access is what makes most servers return a refresh token. It
      # joins a scope that is being asked for, and is never the only one: a
      # request with no scope gets the server's default, which one scope
      # written out would replace.
      def with_offline_access(scope, metadata)
        listed = metadata["scopes_supported"]
        asked = scope.to_s.split
        return scope if asked.empty? || asked.include?("offline_access")
        return scope unless listed.is_a?(Array) && listed.include?("offline_access")

        [*asked, "offline_access"].join(" ")
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
        form, credentials = token_authentication(form, client_secret,
                                                 stored_auth_method(client_secret, auth_method))
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

      # 0.5.0 persisted no method and sent the secret in the form. New flows
      # always persist an explicit method; keep old connected rows usable.
      def stored_auth_method(client_secret, auth_method)
        auth_method ||= client_secret ? "client_secret_post" : "none"
        validate_token_auth_method(auth_method)
        auth_method
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
          form = form.except("client_id")
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

      # missed: collects why an optional document was not read: the status,
      # :unreadable for a body that is no JSON object, nil for no answer. A
      # caller that passes it is told, and gets nil where a body is no JSON.
      def get_json(url, allow_non_public: nil, optional: false, missed: nil)
        targets = Egress.targets(url, allow_non_public:, label: "metadata URL")
        location = Egress.display(targets.first.uri)
        request = Net::HTTP::Get.new(targets.first.uri)
        request["Accept"] = "application/json"
        response = http(targets, request)
        return json_object(response.body, location, missed) if response.code.to_i == 200

        missed&.push(response.code.to_i)
        raise Error, "GET #{location} answered #{response.code}" unless optional
      rescue ConnectionFailure
        missed&.push(nil)
        raise unless optional
      end

      def json_object(body, location, missed)
        object = JSON.parse(body)
        return object if object.is_a?(Hash)
        raise Error, "GET #{location} did not return a JSON object" unless missed

        missed.push(:unreadable) && nil
      rescue JSON::ParserError
        raise Error, "GET #{location} returned invalid JSON" unless missed

        missed.push(:unreadable) && nil
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
        response = post(url, form, basic_auth:, allow_non_public:, label: "token_endpoint")
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
          kind = reason == "invalid_grant" ? InvalidGrantError : TokenError
          raise kind.new("token request failed (#{response.code})#{detail}",
                         status: response.code.to_i, reason: reason)
        end
        payload
      end

      def post(url, form, basic_auth:, allow_non_public:, label:)
        targets = Egress.targets(url, allow_non_public:, label:)
        request = Net::HTTP::Post.new(targets.first.uri)
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request["Accept"] = "application/json"
        request.basic_auth(*basic_auth) if basic_auth
        request.body = URI.encode_www_form(form)
        http(targets, request)
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

      # Exact discovery takes a document that names the address it was read
      # for. Tolerant discovery takes one that names the server, its origin
      # or a path above it. A refusal does not show a query, because a query
      # can hold a secret.
      def validate_resource(candidate, expected, url, tolerant: false)
        raise Error, "protected resource metadata has no resource" unless candidate.is_a?(String)

        resource = canonical(candidate)
        covered = covers?(resource, canonical(url))
        return if tolerant ? covered : resource == canonical(expected)

        refused = Egress.display(URI(tolerant ? url : expected))
        message = "protected resource metadata resource does not match #{refused}"
        raise Error, message unless covered

        named = Egress.display(URI(resource))
        about = named == refused ? "it differs only in the query" : "it names #{named}"
        raise Error, message + tolerable(about)
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

    # The failures that only a new sign-in ends: a token the server refused,
    # and a grant that is spent.
    SIGN_IN_ERRORS = [AuthenticationError, OAuth::InvalidGrantError].freeze
    private_constant :SIGN_IN_ERRORS
  end
end

require_relative "oauth/client_identity"
require_relative "oauth/tolerance"
