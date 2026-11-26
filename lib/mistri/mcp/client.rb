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
    #
    # A server is asked once which revisions of the protocol it speaks. With
    # one that speaks 2026-07-28 there is no handshake and no session: each
    # request carries its own version. An older one gets the handshake of
    # 2025-11-25.
    #
    # listing: takes the value an earlier client's listing returned. A client
    # built with it sends no request until a tool is called.
    class Client
      include Negotiation

      # Times a call is sent again for a server that asks to be called again.
      STATE_ROUNDS = 3
      private_constant :STATE_ROUNDS
      attr_reader :server_info

      def initialize(url: nil, command: nil, env: {}, token: nil, headers: {},
                     client_name: "mistri", open_timeout: 15, read_timeout: 120,
                     allow_non_public: nil, max_tool_pages: 100, max_tools: 10_000,
                     max_record_bytes: DEFAULT_MAX_RECORD_BYTES, listing: nil)
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
        keep(listing) unless listing.nil?
      end

      # The server's tools, and its instructions when it sent any, as JSON a
      # host can store.
      def listing(refresh: false)
        @mutex.synchronize do
          @tools = nil if refresh
          @tools ||= list_tools
          { "tools" => @tools, "instructions" => @instructions,
            "protocolVersion" => @version }.compact
        end
      end

      # The instructions field of the server's initialize result, or nil.
      def instructions
        @mutex.synchronize do
          handshake unless @described
          @instructions
        end
      end

      # The server's tools as it describes them: hashes with "name",
      # "description", and "inputSchema". Cached; refresh: true re-lists.
      def tools(refresh: false)
        @mutex.synchronize do
          @tools = nil if refresh
          @tools ||= list_tools
        end
      end

      # An error raised before the call is sent is raised as a copy tagged
      # NotSent. The error itself may be frozen, or raised again by a later
      # call that was sent.
      def call_tool(name, arguments = {})
        @mutex.synchronize do
          @sent = false
          finished(name, arguments, request("tools/call", { name: name, arguments: arguments }))
        rescue StandardError => e
          raise @sent ? e : e.dup.extend(NotSent)
        end
      end

      def connect
        @mutex.synchronize { handshake }
        self
      end

      def close
        @mutex.synchronize { reset_wire }
        nil
      end

      private

      # The handshake with the one token refresh a request gets.
      def handshake(refreshed: false)
        ensure_connected
      rescue AuthenticationError
        raise if refreshed || !@wire.refreshable?

        handshake(refreshed: true)
      end

      def request(method, params, reconnected: false, refreshed: false, asked: false)
        ensure_connected
        options = wire_options(method, params)
        @sent = true
        rpc(method, params, **options)
      rescue AuthenticationError
        raise if refreshed || !@wire.refreshable?

        # The token callable resolves fresh on retry; hosts refresh there.
        request(method, params, reconnected: reconnected, refreshed: true, asked: asked)
      rescue SessionExpired
        raise Error, "the server expired the session twice in a row" if reconnected

        @connected = false
        @wire.reset_session
        request(method, params, reconnected: true, refreshed: refreshed, asked: asked)
      rescue Error, ProviderError => e
        raise if asked || !stateless? || !form_refused?(e)

        # The server no longer takes the form this client remembered. A
        # request it refused for that did not run, so it is sent again.
        @version = nil
        request(method, params, reconnected: reconnected, refreshed: refreshed, asked: true)
      end

      # Over HTTP a call in the form of 2026-07-28 repeats the parameters its
      # tool marks in headers, so the tool's schema goes with it.
      def wire_options(method, params)
        return {} unless method == "tools/call" && @wire.mirrors?

        tool = (@tools ||= list_tools).find do |listed|
          listed.is_a?(Hash) && listed["name"] == params[:name]
        end
        { mirror: tool && tool["inputSchema"] }
      end

      # In the form of 2026-07-28 a server may answer a call by asking for
      # input. This client declares none it can give, so a call that waits
      # for some ends as the tool's own error, in words a model can pass on. A
      # result that asks for nothing and carries state is sent again with it.
      def finished(name, arguments, result, rounds = STATE_ROUNDS)
        return result unless result.is_a?(Hash) && result["resultType"] == "input_required"

        asked = result["inputRequests"]
        return declined(asked) if rounds.zero? || (asked.is_a?(Hash) && !asked.empty?)

        params = { name: name, arguments: arguments }
        params[:requestState] = result["requestState"] if result.key?("requestState")
        finished(name, arguments, request("tools/call", params), rounds - 1)
      end

      def declined(asked)
        wanted = (asked.is_a?(Hash) ? asked.values : []).first(3).filter_map do |input|
          next unless input.is_a?(Hash)

          params = input["params"]
          [input["method"], (params["message"] if params.is_a?(Hash))].compact.join(": ")
        end
        detail = " (#{wanted.join("; ")[0, 300]})" unless wanted.empty?
        text = "The server asked for input before it would finish this call#{detail}. " \
               "This client gives a server no input, so the call was not finished."
        { "isError" => true, "content" => [{ "type" => "text", "text" => text }] }
      end

      def rpc(method, params, newest: stateless?, **options)
        id = (@serial += 1)
        replayable = method != "tools/call"
        params = params.merge(_meta: described) if newest
        answer = nil
        # A tool may commit its external side effect before the connection dies.
        exchange({ jsonrpc: "2.0", id: id, method: method, params: params },
                 replayable, **options) { |record| answer ||= answer_in(record, id) }
        return outcome(answer) if answer

        raise unanswered(method, replayable)
      rescue WireTimeout => e
        cancel(method, id, "timed out")
        raise if replayable

        raise AmbiguousDeliveryError, unconfirmed(e)
      rescue ResponseTooLargeError, ResponseTooComplexError, WireError => e
        @wire.close
        raise if replayable
        return outcome(answer) if answer

        raise AmbiguousDeliveryError, unconfirmed(e)
      rescue AmbiguousDeliveryError
        @wire.close
        raise
      rescue ProviderError => e
        raise SessionExpired if e.status == 404 && @wire.session?

        raise
      end

      # The wait for an answer can be ended from outside the gem: by a tool's
      # own limit, or by a Timeout the host put around the call. That cancels
      # the request and keeps the server, as the read timeout does.
      def exchange(payload, replayable, **, &)
        settled = false
        @wire.call(payload, replayable: replayable, **, &)
        settled = true
      rescue Mistri::Error
        settled = true
        raise
      ensure
        cancel(payload[:method], payload[:id], "the caller stopped waiting") unless settled
      end

      # A record with a method is the server's own request or notice, whatever
      # its id. The answer may carry the id as a string of the same digits.
      def answer_in(record, id)
        return unless record.is_a?(Hash)
        return reply_to(record) if record.key?("method")

        record if [id, id.to_s].include?(record["id"])
      end

      # An error is raised once its response was read to the end, so the
      # connection it came on is kept.
      def outcome(answer)
        raise rpc_error(answer["error"]) if answer["error"]

        typed(answer["result"])
      end

      # This client declares no capability, so ping is the one request it
      # serves. A reply that cannot be delivered does not fail the call. Since
      # 2026-07-28 a server sends no request and a client no reply.
      def reply_to(record)
        id = record["id"]
        return if stateless?
        return unless id.is_a?(Integer) || (id.is_a?(String) && id.valid_encoding?)

        reply = if record["method"] == "ping"
                  { result: {} }
                else
                  { error: { code: -32_601, message: "Method not found" } }
                end
        @wire.notify({ jsonrpc: "2.0", id: id, **reply })
        nil
      rescue Mistri::Error
        nil
      end

      # The handshake is the one request the spec forbids a client to cancel.
      def cancel(method, id, reason)
        return if method == "initialize"

        @wire.cancel({ jsonrpc: "2.0", method: "notifications/cancelled",
                       params: { requestId: id, reason: reason } })
      rescue Mistri::Error
        nil
      end

      def unanswered(method, replayable)
        detail = "the server sent no matching response to #{method}"
        return Error.new(detail) if replayable

        AmbiguousDeliveryError.new("#{AmbiguousDeliveryError.default_message}: #{detail}")
      end

      def unconfirmed(error)
        "the request was sent but its tool outcome could not be confirmed: " \
          "#{error.message}; the operation may have completed; do not retry automatically; " \
          "verify external state first"
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
          return usable(collected) if cursor.nil?
          raise Error, "tools/list returned a malformed cursor" unless cursor.is_a?(String)
          raise Error, "tools/list repeated a cursor" if seen_cursors[cursor]

          seen_cursors[cursor] = true
        end
        raise Error, "tool discovery exceeded #{@max_tool_pages} pages"
      end

      # Over HTTP the revision of 2026-07-28 has a client leave out a tool
      # whose header marks it cannot honour, and say why.
      def usable(tools)
        return tools unless @wire.mirrors?

        tools.reject do |tool|
          reason = Mirror.violation(tool["inputSchema"]) if tool.is_a?(Hash)
          warn("mistri: the MCP tool #{tool["name"].inspect} was left out: #{reason}") if reason
          reason
        end
      end

      def keep(listing)
        tools, text, version = listing.values_at("tools", "instructions", "protocolVersion") if
          listing.is_a?(Hash)
        unless tools.is_a?(Array) && (text.nil? || text.is_a?(String))
          raise ConfigurationError, "listing: must be a value that Client#listing returned"
        end

        @tools = tools
        @instructions = (text unless text.to_s.empty?)
        @described = true
        @version = version if SUPPORTED_VERSIONS.include?(version)
      end

      def validate_limit(name, value)
        return if value.is_a?(Integer) && value.positive?

        raise ConfigurationError, "#{name}: must be a positive integer"
      end

      def reset_wire
        @wire.end_session
        @wire.close
        @connected = false
        @server_info = nil
      end

      def rpc_error(error)
        Error.new(error["message"] || "MCP request failed",
                  code: error["code"], data: error["data"])
      end
    end
  end
end
