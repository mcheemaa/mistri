# frozen_string_literal: true

module Mistri
  module MCP
    # A Model Context Protocol client: the initialize handshake, tools/list
    # with pagination, and tools/call, over one of two wires. url: speaks
    # Streamable HTTP on the same persistent transport the providers use;
    # command: spawns a local stdio server with credentials in its
    # environment.
    #
    #   Mistri::MCP::Client.new(url: "https://mcp.linear.app/mcp",
    #                           token: -> { connection.bearer_token })
    #   Mistri::MCP::Client.new(command: ["npx", "-y", "some-mcp-server"],
    #                           env: { "API_KEY" => key })
    #
    # HTTP auth is a headers hash or token: a string or a callable. A
    # callable resolves per request, and a 401 retries once after
    # re-resolving, so a host's refresh logic lives in one lambda. A session
    # the server expires (404 with a session attached) transparently
    # re-initializes, per spec.
    # Remote URLs default to public HTTPS. allow_non_public: is consulted only
    # for otherwise blocked addresses and plain HTTP remains loopback-only.
    # max_record_bytes bounds one JSON body, SSE line, or stdio record without
    # imposing a lifetime limit on an SSE stream.
    #
    # One client serializes its calls; parallel tool calls against one
    # server queue rather than interleave.
    class Client
      PROTOCOL_VERSION = "2025-11-25"
      SUPPORTED_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
      attr_reader :server_info

      def initialize(url: nil, command: nil, env: {}, token: nil, headers: {},
                     client_name: "mistri", open_timeout: 15, read_timeout: 120,
                     allow_non_public: nil, max_tool_pages: 100, max_tools: 10_000,
                     max_record_bytes: DEFAULT_MAX_RECORD_BYTES)
        if [url, command].compact.length != 1
          raise ConfigurationError, "pass exactly one of url: or command:"
        end

        validate_limit(:max_tool_pages, max_tool_pages)
        validate_limit(:max_tools, max_tools)
        validate_limit(:max_record_bytes, max_record_bytes)

        @wire = if url
                  Wires::Http.new(url: url, token: token, headers: headers,
                                  open_timeout: open_timeout, read_timeout: read_timeout,
                                  allow_non_public: allow_non_public,
                                  max_record_bytes: max_record_bytes)
                else
                  Wires::Stdio.new(command: command, env: env, read_timeout: read_timeout,
                                   max_record_bytes: max_record_bytes)
                end
        @client_name = client_name
        @mutex = Mutex.new
        @serial = 0
        @connected = false
        @max_tool_pages = max_tool_pages
        @max_tools = max_tools
      end

      # The server's tools as it describes them: hashes with "name",
      # "description", and "inputSchema". Cached; refresh: true re-lists.
      def tools(refresh: false)
        @mutex.synchronize do
          @tools = nil if refresh
          @tools ||= list_tools
        end
      end

      def call_tool(name, arguments = {})
        @mutex.synchronize { request("tools/call", { name: name, arguments: arguments }) }
      end

      def connect
        @mutex.synchronize { ensure_connected }
        self
      end

      def close
        @mutex.synchronize { reset_wire }
        nil
      end

      private

      def ensure_connected
        return if @connected

        result = rpc("initialize", {
                       protocolVersion: PROTOCOL_VERSION,
                       capabilities: {},
                       clientInfo: { name: @client_name, version: Mistri::VERSION }
                     })
        version = result["protocolVersion"].to_s
        unless SUPPORTED_VERSIONS.include?(version)
          raise Error, "server negotiated unsupported protocol version #{version.inspect}"
        end

        @wire.protocol_version = version
        @server_info = result["serverInfo"]
        @wire.notify({ jsonrpc: "2.0", method: "notifications/initialized" })
        @connected = true
      rescue Mistri::Error
        reset_wire
        raise
      end

      def request(method, params, reconnected: false, refreshed: false)
        ensure_connected
        rpc(method, params)
      rescue AuthenticationError
        raise if refreshed || !@wire.refreshable?

        # The token callable resolves fresh on retry; hosts refresh there.
        request(method, params, reconnected: reconnected, refreshed: true)
      rescue SessionExpired
        raise Error, "the server expired the session twice in a row" if reconnected

        @connected = false
        @wire.reset_session
        request(method, params, reconnected: true, refreshed: refreshed)
      end

      def rpc(method, params)
        id = (@serial += 1)
        payload = { jsonrpc: "2.0", id: id, method: method, params: params }
        result = nil
        responded = false
        replayable = method != "tools/call"
        # A tool may commit its external side effect before the connection dies.
        @wire.call(payload, replayable: replayable) do |record|
          next unless record.is_a?(Hash) && record["id"] == id

          responded = true
          raise rpc_error(record["error"]) if record["error"]

          result = record["result"]
        end
        unless responded
          detail = "the server sent no matching response to #{method}"
          raise Error, detail if replayable

          raise AmbiguousDeliveryError, "#{AmbiguousDeliveryError.default_message}: #{detail}"
        end

        result
      rescue ResponseTooLargeError, ResponseTooComplexError, WireError => e
        reset_wire
        raise if replayable
        return result if responded

        message = "the request was sent but its tool outcome could not be confirmed: " \
                  "#{e.message}; the operation may have completed; do not retry automatically; " \
                  "verify external state first"
        raise AmbiguousDeliveryError, message
      rescue AmbiguousDeliveryError
        reset_wire
        return result if responded

        raise
      rescue ProviderError => e
        raise SessionExpired if e.status == 404 && @wire.session?

        raise
      end

      def list_tools
        collected = []
        cursor = nil
        seen_cursors = {}
        @max_tool_pages.times do
          result = request("tools/list", cursor ? { cursor: cursor } : {})
          raise Error, "tools/list returned a malformed result" unless result.is_a?(Hash)

          page = result["tools"]
          raise Error, "tools/list returned a malformed tools collection" unless page.is_a?(Array)
          if collected.length + page.length > @max_tools
            raise Error, "tool discovery exceeded #{@max_tools} tools"
          end

          collected.concat(page)
          cursor = result["nextCursor"]
          return collected if cursor.nil?
          raise Error, "tools/list returned a malformed cursor" unless cursor.is_a?(String)
          raise Error, "tools/list repeated a cursor" if seen_cursors[cursor]

          seen_cursors[cursor] = true
        end
        raise Error, "tool discovery exceeded #{@max_tool_pages} pages"
      end

      def validate_limit(name, value)
        return if value.is_a?(Integer) && value.positive?

        raise ConfigurationError, "#{name}: must be a positive integer"
      end

      def reset_wire
        @wire.close
        @wire.reset_session
        @connected = false
        @server_info = nil
      end

      def rpc_error(error)
        Error.new(error["message"] || "MCP request failed", code: error["code"])
      end
    end
  end
end
