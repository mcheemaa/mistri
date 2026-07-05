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
                     resource_scopes: [], as_scopes: [], basic_token_auth: false)
        @challenge_header = challenge_header
        @registration = registration
        @openid_only = openid_only
        @resource_scopes = resource_scopes
        @as_scopes = as_scopes
        @basic_token_auth = basic_token_auth
        @registrations = []
        @token_requests = []
        @stub = StubServer.new { |socket, request| route(socket, request) }
      end

      def origin = @stub.origin
      def url = "#{origin}/mcp"
      def stop = @stub.stop

      private

      def route(socket, request)
        verb, path, = request[:line].split
        case [verb, path.split("?").first]
        in ["POST", "/mcp"] then challenge(socket)
        in ["GET", "/.well-known/oauth-protected-resource/mcp"] then resource_metadata(socket)
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
          metadata = "#{origin}/.well-known/oauth-protected-resource/mcp"
          headers["WWW-Authenticate"] = "Bearer resource_metadata=\"#{metadata}\""
        end
        @stub.respond_json(socket, { "error" => "unauthorized" }, status: 401, headers: headers)
      end

      def resource_metadata(socket)
        document = { "resource" => url, "authorization_servers" => [origin] }
        document["scopes_supported"] = @resource_scopes if @resource_scopes.any?
        @stub.respond_json(socket, document)
      end

      def server_metadata(socket, openid:)
        if @openid_only != openid
          return @stub.respond_json(socket, { "error" => "not found" }, status: 404)
        end

        metadata = { "issuer" => origin,
                     "authorization_endpoint" => "#{origin}/authorize",
                     "token_endpoint" => "#{origin}/token" }
        metadata["scopes_supported"] = @as_scopes if @as_scopes.any?
        metadata["registration_endpoint"] = "#{origin}/register" if @registration
        @stub.respond_json(socket, metadata)
      end

      def register(socket, request)
        @registrations << JSON.parse(request[:body])
        method = @basic_token_auth ? "client_secret_basic" : "client_secret_post"
        @stub.respond_json(socket, { "client_id" => "app-123", "client_secret" => "shh",
                                     "token_endpoint_auth_method" => method },
                           status: 201)
      end

      def token(socket, request)
        form = URI.decode_www_form(request[:body]).to_h
        @token_requests << form.merge("_authorization" => request[:headers]["authorization"])
        case form["grant_type"]
        when "authorization_code"
          if form["code"] == "good-code" && !form["code_verifier"].to_s.empty?
            @stub.respond_json(socket, { "access_token" => "at-1", "refresh_token" => "rt-1",
                                         "expires_in" => 3600, "scope" => "tools" })
          else
            @stub.respond_json(socket, { "error" => "invalid_grant" }, status: 400)
          end
        when "refresh_token"
          if form["refresh_token"] == "rt-1"
            @stub.respond_json(socket, { "access_token" => "at-2", "refresh_token" => "rt-2",
                                         "expires_in" => 3600 })
          else
            @stub.respond_json(socket, { "error" => "invalid_grant" }, status: 400)
          end
        else
          @stub.respond_json(socket, { "error" => "unsupported_grant_type" }, status: 400)
        end
      end
    end
  end
end
