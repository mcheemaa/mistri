# frozen_string_literal: true

module Mistri
  module MCP
    # Which revision of the protocol a client speaks with its server. Since
    # 2026-07-28 there is no handshake: a request carries its own version, and
    # a client that also speaks an older revision first asks the server which
    # it has. Part of Client, which gives it the wire and rpc.
    module Negotiation
      PROTOCOL_VERSION = "2026-07-28"
      HANDSHAKE_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
      SUPPORTED_VERSIONS = [PROTOCOL_VERSION, *HANDSHAKE_VERSIONS].freeze
      # The errors that only a server of 2026-07-28 sends: a header that does
      # not match, a capability the client lacks, a version it does not speak.
      NEWER_ERRORS = [-32_020, -32_021, -32_022].freeze
      UNSUPPORTED_VERSION = -32_022
      # A refusal with one of these says nothing about the revision.
      UNRELATED_STATUSES = [401, 403, 408, 429].freeze
      private_constant :HANDSHAKE_VERSIONS, :NEWER_ERRORS, :UNSUPPORTED_VERSION,
                       :UNRELATED_STATUSES

      private

      # A server is asked once which revisions it speaks, and the answer is
      # kept. A server on stdio that was slow to start answers too late and
      # then refuses the handshake, so it is asked once more with the full
      # wait.
      def ensure_connected
        return @wire.protocol_version = @version if stateless?
        return if @connected && @wire.open?

        silent = @version.nil? && discover(@wire.probe_wait) == :silent
        return if stateless?

        begin
          open_session
        rescue Error, ProviderError
          raise unless silent && discover(nil) == :newest
        end
      rescue Mistri::Error
        reset_wire
        raise
      end

      def stateless? = @version == PROTOCOL_VERSION

      # Asks in the form of 2026-07-28. An older server does not know the
      # request: whatever it answers that is not an error of that revision
      # says so, and so does silence on stdio. Never one error code alone. A
      # refusal to authorize, a server error and a lost connection say
      # nothing about the revision.
      def discover(wait, again: false)
        @wire.protocol_version = PROTOCOL_VERSION
        answer = question(wait, again)
        answer.is_a?(Symbol) ? answer : adopt(answer)
      end

      # The server's answer, or what its failure to give one says.
      def question(wait, again)
        rpc("server/discover", {}, newest: true, wait: wait)
      rescue WireTimeout
        raise unless wait

        older(:silent)
      rescue Error, ProviderError => e
        raise if e.is_a?(ProviderError) && unrelated?(e.status)

        code, data = refusal_of(e)
        return older(:older) unless NEWER_ERRORS.include?(code)
        raise if again || code != UNSUPPORTED_VERSION

        offered(data.is_a?(Hash) ? data["supported"] : nil) { discover(wait, again: true) }
      end

      def adopt(result)
        return older(:older) unless result.is_a?(Hash) && result["supportedVersions"].is_a?(Array)

        offered(result["supportedVersions"]) do
          meta = result["_meta"]
          @server_info = meta["io.modelcontextprotocol/serverInfo"] if meta.is_a?(Hash)
          text = result["instructions"]
          @instructions = (text if text.is_a?(String) && !text.empty?)
          @described = true
          @version = PROTOCOL_VERSION
          :newest
        end
      end

      # The block runs when the server offers 2026-07-28. A server that
      # offers only older revisions gets the handshake.
      def offered(versions)
        versions = Array(versions)
        return yield if versions.include?(PROTOCOL_VERSION)
        return older(:older) if versions.intersect?(HANDSHAKE_VERSIONS)

        raise Error, "the server speaks no protocol version this client does: " \
                     "#{versions.first(8).join(", ")[0, 120]}"
      end

      def older(answer)
        @wire.protocol_version = nil
        answer
      end

      def unrelated?(status) = status.nil? || status >= 500 || UNRELATED_STATUSES.include?(status)

      # The JSON-RPC error a failure carries: its own, or the one in the body
      # of an HTTP refusal.
      def refusal_of(error)
        return [error.code, error.data] if error.is_a?(Error)

        inner = JSON.parse(error.body.to_s)
        inner = inner["error"] if inner.is_a?(Hash)
        [inner["code"], inner["data"]] if inner.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def open_session
        result = rpc("initialize", {
                       protocolVersion: HANDSHAKE_VERSIONS.first,
                       capabilities: {},
                       clientInfo: { name: @client_name, version: Mistri::VERSION }
                     })
        version = result["protocolVersion"].to_s
        unless HANDSHAKE_VERSIONS.include?(version)
          raise Error, "server negotiated unsupported protocol version #{version.inspect}"
        end

        @wire.protocol_version = version
        @version = version
        @server_info = result["serverInfo"]
        text = result["instructions"]
        @instructions = (text if text.is_a?(String) && !text.empty?)
        @described = true
        @wire.notify({ jsonrpc: "2.0", method: "notifications/initialized" })
        @connected = true
      end

      def form_refused?(error)
        code, = refusal_of(error)
        return true if code == UNSUPPORTED_VERSION

        error.is_a?(ProviderError) && !unrelated?(error.status) && !NEWER_ERRORS.include?(code)
      end

      # What every request says of itself since 2026-07-28, where no handshake
      # says it once.
      def described
        { "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
          "io.modelcontextprotocol/clientInfo" => { name: @client_name, version: Mistri::VERSION },
          "io.modelcontextprotocol/clientCapabilities" => {} }
      end

      # A result names its type since 2026-07-28. None means complete, and one
      # this client does not know is not a result it can use.
      def typed(result)
        type = result["resultType"] if result.is_a?(Hash)
        return result if type.nil? || %w[complete input_required].include?(type)

        raise Error, "the server returned a result of the unknown type #{type.to_s[0, 60].inspect}"
      end
    end
  end
end
