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
    #
    # on_notification: is called with the method and the params of each
    # notification the server sends while the client reads, such as a changed
    # tool list. It runs inside the call, so it must not use this client.
    # progress: true asks for progress with each tool call. state says whether
    # the server answered, could not be reached, or needs a sign-in, and
    # failure says why.
    class Client
      include Negotiation
      include Conversation

      # Times a call is sent again for a server that asks to be called again.
      STATE_ROUNDS = 3
      # The failures that leave a server as it was, and the ones that say it
      # could not be used.
      KEPT = [WireTimeout, ResponseTooLargeError, ResponseTooComplexError].freeze
      DOWN = [ProviderError, WireError, SystemCallError].freeze
      private_constant :STATE_ROUNDS, :KEPT, :DOWN
      attr_reader :server_info, :state, :failure

      def initialize(url: nil, command: nil, env: {}, token: nil, headers: {},
                     client_name: "mistri", open_timeout: 15, read_timeout: 120,
                     allow_non_public: nil, max_tool_pages: 100, max_tools: 10_000,
                     max_record_bytes: DEFAULT_MAX_RECORD_BYTES, listing: nil,
                     on_notification: nil, progress: false)
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
        @on_notification = on_notification
        @progress = progress
        @state = :idle
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
        watched do
          @tools = nil if refresh
          @tools ||= list_tools
          { "tools" => @tools, "instructions" => @instructions,
            "protocolVersion" => @version, "resources" => @resources || nil }.compact
        end
      end

      # The instructions field of the server's initialize result, or nil.
      def instructions
        watched do
          handshake unless @described
          @instructions
        end
      end

      # The server's tools as it describes them: hashes with "name",
      # "description", and "inputSchema". Cached; refresh: true re-lists.
      def tools(refresh: false)
        watched do
          @tools = nil if refresh
          @tools ||= list_tools
        end
      end

      # Whether the server said it has resources. A client built from a stored
      # listing answers from the listing.
      def resources?
        watched do
          handshake unless @described
          @resources == true
        end
      end

      # The contents of one resource: hashes with "uri", "mimeType", and "text"
      # or "blob", which is base64 of its bytes.
      def read_resource(uri)
        watched do
          result = request("resources/read", { uri: uri })
          contents = result["contents"] if result.is_a?(Hash)
          return contents if contents.is_a?(Array)

          raise Error, "resources/read returned a malformed result"
        end
      end

      # An error raised before the call is sent is raised as a copy tagged
      # NotSent. The error itself may be frozen, or raised again by a later
      # call that was sent. One client runs one call at a time, so a call
      # that is ended while it waits for another was not sent either.
      def call_tool(name, arguments = {})
        waiting = true
        @mutex.synchronize do
          waiting = false
          @sent = false
          finished(name, arguments, request("tools/call", { name: name, arguments: arguments }))
        rescue StandardError => e
          note(e)
          raise unsent?(e) ? tagged(e) : e
        end
      rescue StandardError => e
        raise waiting ? tagged(e) : e
      end

      def connect
        watched { handshake }
        self
      end

      def close
        @mutex.synchronize do
          reset_wire
          @state = :idle
          @failure = nil
        end
        nil
      end

      private

      def watched
        @mutex.synchronize do
          yield
        rescue StandardError => e
          note(e)
          raise
        end
      end

      # A call was not sent when it failed before its request, or when no
      # connection could be opened to send it on.
      def unsent?(error) = !@sent || Transport.unopened?(error.cause)

      # A copy, so the error a host owns is not changed. clone keeps a module
      # the host extended its error with, which dup would drop.
      def tagged(error)
        error.is_a?(NotSent) ? error : error.clone(freeze: false).extend(NotSent)
      end

      # What a failure says of the server: that it refused to authorize, or
      # that it could not be used. Its own answer, a call that timed out and
      # an answer over a limit leave the state as it was, and so does an
      # error of the host's own.
      def note(error)
        return if [error, error.cause].any? { |known| KEPT.any? { |kind| known.is_a?(kind) } }

        refused = SIGN_IN_ERRORS.any? { |kind| error.is_a?(kind) }
        return unless refused || DOWN.any? { |kind| error.is_a?(kind) }

        @state = refused ? :needs_sign_in : :failed
        @failure = error.message
      end

      # The handshake with the one token refresh a request gets.
      def handshake(refreshed: false)
        ensure_connected
      rescue AuthenticationError => e
        raise if refreshed || !renewable?(e)

        handshake(refreshed: true)
      end

      def request(method, params, reconnected: false, refreshed: false, asked: false)
        ensure_connected
        options = wire_options(method, params)
        @sent = true
        rpc(method, params, **options)
      rescue AuthenticationError => e
        raise if refreshed || !renewable?(e)

        # The token callable resolves fresh on retry; hosts refresh there.
        request(method, params, reconnected: reconnected, refreshed: true, asked: asked)
      rescue SessionExpired
        raise Error, "the server expired the session twice in a row" if reconnected

        @connected = false
        @wire.reset_session
        request(method, params, reconnected: true, refreshed: refreshed, asked: asked)
      rescue Error, ProviderError => e
        raise if asked || !stateless? || !form_refused?(e)

        # The server may no longer take the form this client remembered, so
        # it is asked again. One that still speaks this revision gave its
        # answer. One that now speaks an older revision refused the request
        # for its form, so the request did not run and is sent again.
        @version = nil
        ensure_connected
        raise e if stateless?

        request(method, params, reconnected: reconnected, refreshed: refreshed, asked: true)
      end

      # A refused token is worth asking for again when the host gives tokens
      # by a callable. A 403 that asks for more scope is not: a new token of
      # the same grant has the same scope, so the host signs in again.
      def renewable?(error)
        return false unless @wire.refreshable?
        return false if OAuth.challenge(error)["error"] == "insufficient_scope"

        @wire.token_refused
        true
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

      def rpc(method, params, newest: stateless?, **options)
        id = (@serial += 1)
        replayable = method != "tools/call"
        meta = meta_of(method, id, newest)
        params = params.merge(_meta: meta) unless meta.empty?
        answer = nil
        # A tool may commit its external side effect before the connection dies.
        exchange({ jsonrpc: "2.0", id: id, method: method, params: params },
                 replayable, **options) do |record|
          taken = answer_in(record, id)
          answer ||= taken
        end
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

        @instructions = (text unless text.to_s.empty?)
        @resources = listing["resources"] == true
        @described = true
        @version = version if SUPPORTED_VERSIONS.include?(version)
        @wire.protocol_version = @version if stateless?
        @tools = usable(tools)
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
