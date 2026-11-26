# frozen_string_literal: true

# The rules for application_type and for the address of a client ID metadata
# document are adapted from the Model Context Protocol Ruby SDK
# (lib/mcp/client/oauth/discovery.rb), Apache License 2.0. See NOTICE.

module Mistri
  module MCP
    # How the application names itself to an authorization server.
    module OAuth
      module_function

      # OpenID Connect servers read a registration with no application_type as
      # a web application, and refuse a loopback redirect URI for one.
      def application_type(redirect_uri)
        Egress.loopback?(URI(redirect_uri).hostname) ? "native" : "web"
      end

      # The document a host serves at the address it passes to start as
      # client_metadata_url:. redirect_uris holds every redirect URI the
      # application signs in with.
      def client_metadata(url:, client_name:, redirect_uris:)
        validate_client_metadata_url(url)
        { "client_id" => url, "client_name" => client_name,
          "redirect_uris" => Array(redirect_uris).map { |uri| Egress.redirect_uri(uri) },
          "grant_types" => %w[authorization_code refresh_token],
          "response_types" => ["code"], "token_endpoint_auth_method" => "none" }
      end

      def validate_client_metadata_url(url)
        return if client_metadata_url?(url)

        raise ConfigurationError,
              "client_metadata_url: must be an https URL with a path and no query or fragment"
      end

      # The address is the client ID, so two spellings of one document must
      # not exist: no query, no fragment, no credentials and no dot segments.
      def client_metadata_url?(url)
        uri = URI.parse(url.to_s)
        return false unless uri.scheme&.downcase == "https" && !uri.host.to_s.empty?
        return false if uri.fragment || uri.query || uri.user || uri.password

        path = uri.path.to_s
        return false if path.empty? || path == "/"

        !path.gsub(/%2e/i, ".").split("/", -1).intersect?(%w[. ..])
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
