# frozen_string_literal: true

require "uri"

module Mistri
  module MCP
    # A Model Context Protocol client over Streamable HTTP: the initialize
    # handshake, tools/list with pagination, and tools/call, on the same
    # persistent transport the providers use. Responses arrive as JSON or as
    # an SSE stream; both decode the same way.
    #
    # Auth is a headers hash or token: a string or a callable. A callable
    # resolves per request, and a 401 retries once after re-resolving, so a
    # host's refresh logic lives in one lambda. A session the server expires
    # (404 with a session attached) transparently re-initializes, per spec.
    #
    # One client serializes its calls; parallel tool calls against one
    # server queue rather than interleave on the socket.
    class Client
      PROTOCOL_VERSION = "2025-06-18"
      SUPPORTED_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
      LOOPBACK = %w[localhost 127.0.0.1 ::1].freeze

      attr_reader :server_info

      def initialize(url:, token: nil, headers: {}, client_name: "mistri",
                     open_timeout: 15, read_timeout: 120)
        uri = URI(url)
        if token && uri.scheme == "http" && !LOOPBACK.include?(uri.host)
          raise ConfigurationError,
                "refusing to send a bearer token over plain HTTP to #{uri.host}"
        end

        @path = uri.path.empty? ? "/" : uri.path
        @path = "#{@path}?#{uri.query}" if uri.query
        @transport = Transport.new(origin: "#{uri.scheme}://#{uri.host}:#{uri.port}",
                                   open_timeout: open_timeout, read_timeout: read_timeout)
        @token = token
        @headers = headers
        @client_name = client_name
        @mutex = Mutex.new
        @serial = 0
        @session_id = nil
        @protocol_version = nil
        @connected = false
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
        @transport.close
        @connected = false
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

        @protocol_version = version
        @server_info = result["serverInfo"]
        notify("notifications/initialized")
        @connected = true
      end

      def request(method, params, reconnected: false, refreshed: false)
        ensure_connected
        rpc(method, params)
      rescue AuthenticationError
        raise if refreshed || !@token.respond_to?(:call)

        # The callable resolves fresh on the retry; the host refreshes there.
        request(method, params, reconnected: reconnected, refreshed: true)
      rescue SessionExpired
        raise Error, "the server expired the session twice in a row" if reconnected

        @connected = false
        @session_id = nil
        request(method, params, reconnected: true, refreshed: refreshed)
      end

      def rpc(method, params)
        id = (@serial += 1)
        payload = { jsonrpc: "2.0", id: id, method: method, params: params }
        result = nil
        responded = false
        meta = @transport.post_either(@path, body: payload, headers: request_headers) do |record|
          next unless record.is_a?(Hash) && record["id"] == id

          responded = true
          raise rpc_error(record["error"]) if record["error"]

          result = record["result"]
        end
        capture_session(meta)
        raise Error, "the server sent no response to #{method}" unless responded

        result
      rescue ProviderError => e
        raise SessionExpired if e.status == 404 && @session_id

        raise
      end

      def notify(method)
        payload = { jsonrpc: "2.0", method: method }
        discard = ->(_record) {}
        @transport.post_either(@path, body: payload, headers: request_headers, &discard)
        nil
      end

      def list_tools
        collected = []
        cursor = nil
        loop do
          result = request("tools/list", cursor ? { cursor: cursor } : {})
          collected.concat(Array(result["tools"]))
          cursor = result["nextCursor"]
          break unless cursor
        end
        collected
      end

      def request_headers
        headers = { "Accept" => "application/json, text/event-stream" }
        headers.merge!(@headers)
        headers["Authorization"] = "Bearer #{resolve_token}" if @token
        headers["Mcp-Session-Id"] = @session_id if @session_id
        headers["MCP-Protocol-Version"] = @protocol_version if @protocol_version
        headers
      end

      def resolve_token
        @token.respond_to?(:call) ? @token.call : @token
      end

      def capture_session(meta)
        session = meta && meta["mcp-session-id"]
        @session_id = session if session
      end

      def rpc_error(error)
        Error.new(error["message"] || "MCP request failed", code: error["code"])
      end
    end
  end
end
