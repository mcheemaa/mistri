# frozen_string_literal: true

# The rule for a resource that covers a server's address is adapted from the
# Model Context Protocol Ruby SDK (lib/mcp/client/oauth/discovery.rb), Apache
# License 2.0. See NOTICE.

module Mistri
  module MCP
    # What tolerant: true accepts where exact discovery refuses. Each rule is
    # one the official SDKs apply to servers that predate exact metadata.
    module OAuth
      module_function

      # A resource document may stand for the origin, or for a path above the
      # server's. One that names a query covers that query alone.
      def covers?(resource, url)
        named = URI(resource)
        server = URI(url)
        return false unless Egress.origin(named) == Egress.origin(server)

        above = named.path.to_s.chomp("/")
        return false unless server.path.to_s == above || server.path.to_s.start_with?("#{above}/")

        named.query.nil? || named.query == server.query
      end

      # An issuer taken from a URL is often written with the slash its
      # metadata leaves out, or without the one it has.
      def same_issuer?(first, second)
        return false unless first.is_a?(String) && second.is_a?(String)

        first == second || first == "#{second}/" || "#{first}/" == second
      end

      # A document that was looked for is not published when every answer
      # says so: a redirect, a refusal other than 429, or a body that is no
      # JSON object. No answer, a 429 and a 5xx say nothing of what is there.
      def unpublished?(missed)
        missed.all? do |answer|
          answer == :unreadable || ((300..499).cover?(answer) && answer != 429)
        end
      end

      # The endpoints of the 2025-03-26 revision, for an authorization server
      # that publishes no metadata. That revision required PKCE.
      def default_metadata(authority)
        base = authority.chomp("/")
        { "issuer" => authority, "authorization_endpoint" => "#{base}/authorize",
          "token_endpoint" => "#{base}/token", "registration_endpoint" => "#{base}/register",
          "code_challenge_methods_supported" => ["S256"] }
      end
    end
  end
end
