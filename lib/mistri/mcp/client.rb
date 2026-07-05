# frozen_string_literal: true

require "uri"

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
    #
    # One client serializes its calls; parallel tool calls against one
    # server queue rather than interleave.
    class Client
      PROTOCOL_VERSION = "2025-06-18"
      SUPPORTED_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
      LOOPBACK = %w[localhost 127.0.0.1 ::1].freeze

      attr_reader :server_info

      def initialize(url: nil, command: nil, env: {}, token: nil, headers: {},
                     client_name: "mistri", open_timeout: 15, read_timeout: 120)
        if [url, command].compact.length != 1
          raise ConfigurationError, "pass exactly one of url: or command:"
        end

        if url && token && URI(url).scheme == "http" && !LOOPBACK.include?(URI(url).host)
          raise ConfigurationError,
                "refusing to send a bearer token over plain HTTP to #{URI(url).host}"
        end

        @wire = if url
                  Wires::Http.new(url: url, token: token, headers: headers,
                                  open_timeout: open_timeout, read_timeout: read_timeout)
                else
                  Wires::Stdio.new(command: command, env: env, read_timeout: read_timeout)
                end
        @client_name = client_name
        @mutex = Mutex.new
        @serial = 0
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
        @wire.close
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

        @wire.protocol_version = version
        @server_info = result["serverInfo"]
        @wire.notify({ jsonrpc: "2.0", method: "notifications/initialized" })
        @connected = true
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
        @wire.call(payload) do |record|
          next unless record.is_a?(Hash) && record["id"] == id

          responded = true
          raise rpc_error(record["error"]) if record["error"]

          result = record["result"]
        end
        raise Error, "the server sent no response to #{method}" unless responded

        result
      rescue ProviderError => e
        raise SessionExpired if e.status == 404 && @wire.session?

        raise
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

      def rpc_error(error)
        Error.new(error["message"] || "MCP request failed", code: error["code"])
      end
    end
  end
end
