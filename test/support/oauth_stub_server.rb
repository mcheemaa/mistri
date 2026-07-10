# frozen_string_literal: true

require "json"
require "uri"
require_relative "stub_server"

module Mistri
  module Test
    # An in-process authorization server + protected MCP resource speaking
    # the discovery-and-token subset the MCP spec requires: 401 challenge,
    # RFC 9728 resource metadata, RFC 8414 (or OpenID) server metadata,
    # RFC 7591 registration, and a form-encoded token endpoint.
    class OauthStubServer
      attr_reader :registrations, :token_requests

      def initialize(challenge_header: true, registration: true, openid_only: false,
                     resource_scopes: [], as_scopes: [], basic_token_auth: false,
                     challenge_scope: nil, challenge_metadata: :default,
                     path_metadata: true, root_metadata: false, resource: :default,
                     authorization_server: :default, authorization_servers: nil,
                     issuer: :default, pkce: ["S256"], endpoints: {},
                     metadata_redirect: nil, oauth_metadata_status: nil,
                     path_metadata_status: nil, token_response: nil,
                     token_error: "invalid_grant", token_error_description: nil,
                     token_auth_methods: nil,
                     registration_secret: "shh", registration_auth_method: nil,
                     query: nil)
        @challenge_header = challenge_header
        @challenge_scope = challenge_scope
        @challenge_metadata = challenge_metadata
        @registration = registration
        @openid_only = openid_only
        @path_metadata = path_metadata
        @root_metadata = root_metadata
        @path_metadata_status = path_metadata_status
        @resource = resource
        @authorization_server = authorization_server
        @authorization_servers = authorization_servers
        @issuer = issuer
        @pkce = pkce
        @endpoints = endpoints
        @metadata_redirect = metadata_redirect
        @oauth_metadata_status = oauth_metadata_status
        @resource_scopes = resource_scopes
        @as_scopes = as_scopes
        @basic_token_auth = basic_token_auth
        @token_response = token_response
        @token_error = token_error
        @token_error_description = token_error_description
        @token_auth_methods = token_auth_methods
        @registration_secret = registration_secret
        @registration_auth_method = registration_auth_method
        @query = query
        @registrations = []
        @token_requests = []
        @stub = StubServer.new { |socket, request| route(socket, request) }
      end

      def origin = @stub.origin
      def url = @query ? "#{origin}/mcp?#{@query}" : "#{origin}/mcp"
      def requests = @stub.requests
      def stop = @stub.stop

      private

      def route(socket, request)
        verb, path, = request[:line].split
        case [verb, path.split("?").first]
        in ["POST", "/mcp"] then challenge(socket)
        in ["GET", "/.well-known/oauth-protected-resource/mcp"]
          if @path_metadata_status
            @stub.respond_json(socket, { "error" => "path metadata" },
                               status: @path_metadata_status)
          else
            @path_metadata ? resource_metadata(socket, root: false) : not_found(socket)
          end
        in ["GET", "/.well-known/oauth-protected-resource"]
          @root_metadata ? resource_metadata(socket, root: true) : not_found(socket)
        in ["GET", "/.well-known/oauth-authorization-server"] then server_metadata(socket,
                                                                                   openid: false)
        in ["GET", "/.well-known/openid-configuration"] then server_metadata(socket, openid: true)
        in ["POST", "/register"] then register(socket, request)
        in ["POST", "/token"] then token(socket, request)
        else @stub.respond_json(socket, { "error" => "not found" }, status: 404)
        end
        nil
      end

      def challenge(socket)
        headers = {}
        if @challenge_header
          metadata = if @challenge_metadata == :default
                       "#{origin}/.well-known/oauth-protected-resource/mcp"
                     else
                       @challenge_metadata
                     end
          params = []
          params << "resource_metadata=\"#{metadata}\"" if metadata
          params << "scope=\"#{@challenge_scope}\"" if @challenge_scope
          headers["WWW-Authenticate"] = "Basic realm=\"stub\", Bearer #{params.join(", ")}"
        end
        @stub.respond_json(socket, { "error" => "unauthorized" }, status: 401, headers: headers)
      end

      def resource_metadata(socket, root:)
        if @metadata_redirect
          return @stub.respond_json(socket, "", status: 302,
                                                headers: { "Location" => @metadata_redirect })
        end

        resource = setting(@resource, root ? origin : url)
        authority = setting(@authorization_server, origin)
        servers = @authorization_servers ? setting(@authorization_servers, nil) : [authority]
        document = { "authorization_servers" => servers }
        document["resource"] = resource if resource
        document["scopes_supported"] = @resource_scopes if @resource_scopes.any?
        @stub.respond_json(socket, document)
      end

      def server_metadata(socket, openid:)
        if !openid && @oauth_metadata_status
          return @stub.respond_json(socket, { "error" => "oauth metadata" },
                                    status: @oauth_metadata_status)
        end
        if @openid_only != openid
          return @stub.respond_json(socket, { "error" => "not found" }, status: 404)
        end

        issuer = setting(@issuer, origin)
        metadata = { "issuer" => issuer,
                     "authorization_endpoint" => "#{origin}/authorize",
                     "token_endpoint" => "#{origin}/token" }
        metadata["code_challenge_methods_supported"] = @pkce if @pkce
        metadata["scopes_supported"] = @as_scopes if @as_scopes.any?
        if @token_auth_methods
          metadata["token_endpoint_auth_methods_supported"] = @token_auth_methods
        end
        metadata["registration_endpoint"] = "#{origin}/register" if @registration
        @endpoints.each { |key, value| metadata[key] = setting(value, value) }
        @stub.respond_json(socket, metadata)
      end

      def register(socket, request)
        @registrations << JSON.parse(request[:body])
        method = @registration_auth_method ||
                 (@basic_token_auth ? "client_secret_basic" : "client_secret_post")
        @stub.respond_json(socket, { "client_id" => "app-123",
                                     "client_secret" => @registration_secret,
                                     "token_endpoint_auth_method" => method },
                           status: 201)
      end

      def token(socket, request)
        form = URI.decode_www_form(request[:body]).to_h
        @token_requests << form.merge("_authorization" => request[:headers]["authorization"])
        case form["grant_type"]
        when "authorization_code"
          if form["code"] == "good-code" && !form["code_verifier"].to_s.empty?
            response = @token_response ||
                       { "access_token" => "at-1", "refresh_token" => "rt-1",
                         "token_type" => "Bearer", "expires_in" => 3600, "scope" => "tools" }
            @stub.respond_json(socket, response)
          else
            error = { "error" => @token_error }
            error["error_description"] = @token_error_description if @token_error_description
            @stub.respond_json(socket, error, status: 400)
          end
        when "refresh_token"
          if form["refresh_token"] == "rt-1"
            response = @token_response ||
                       { "access_token" => "at-2", "refresh_token" => "rt-2",
                         "token_type" => "Bearer", "expires_in" => 3600 }
            @stub.respond_json(socket, response)
          else
            @stub.respond_json(socket, { "error" => "invalid_grant" }, status: 400)
          end
        else
          @stub.respond_json(socket, { "error" => "unsupported_grant_type" }, status: 400)
        end
      end

      def not_found(socket)
        @stub.respond_json(socket, { "error" => "not found" }, status: 404)
      end

      def setting(value, fallback)
        return fallback if value == :default

        value.respond_to?(:call) ? value.call(self) : value
      end
    end
  end
end
