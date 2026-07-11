# frozen_string_literal: true

require "json"
require_relative "stub_server"

module Mistri
  module Test
    # An in-process MCP server speaking Streamable HTTP: enough protocol to
    # test the client and bridge hermetically. Tools are lambdas returning a
    # String (wrapped as text content) or a raw result hash. Toggles cover
    # the interesting server behaviors: SSE or plain JSON replies, session
    # ids, list pagination, bearer auth, and one session expiry.
    class McpStubServer
      attr_reader :calls, :initializes

      def initialize(tools: {}, sse: true, session: nil, page_size: nil,
                     require_token: nil, expire_after: nil, protocol: "2025-11-25",
                     drop_after: nil, malformed_after: nil, empty_after: nil,
                     next_cursor: nil, trailing_after: nil, trailing_record: nil)
        @tools = tools
        @sse = sse
        @session = session
        @page_size = page_size
        @require_token = require_token
        @expire_after = expire_after
        @protocol = protocol
        @drop_after = drop_after
        @malformed_after = malformed_after
        @empty_after = empty_after
        @trailing_after = trailing_after
        @trailing_record = trailing_record
        @trailed = false
        @next_cursor = next_cursor
        @dropped = false
        @malformed = false
        @emptied = false
        @calls = []
        @initializes = 0
        @served = 0
        @expired = false
        @stub = StubServer.new { |socket, request| route(socket, request) }
      end

      def url = "#{@stub.origin}/mcp"
      def requests = @stub.requests
      def stop = @stub.stop

      def bodies
        requests.filter_map { |r| JSON.parse(r[:body]) unless r[:body].to_s.empty? }
      end

      private

      def route(socket, request)
        message = JSON.parse(request[:body])
        return unauthorized(socket) if @require_token && !authorized?(request)
        return expire(socket) if expire?(request)

        @served += 1
        return @stub.respond_json(socket, "", status: 202) unless message["id"]

        result = result_for(message)
        if message["method"] == @drop_after && !@dropped
          @dropped = true
          return :close
        end
        if message["method"] == @malformed_after && !@malformed
          @malformed = true
          @stub.respond_json(socket, "{")
          return :close
        end
        if message["method"] == @empty_after && !@emptied
          @emptied = true
          return @stub.respond_json(socket, "", status: 202)
        end

        respond(socket, message["id"], result, headers: session_headers(message),
                                               method: message["method"])
        nil
      end

      def result_for(message)
        case message["method"]
        when "initialize"
          @initializes += 1
          { "protocolVersion" => @protocol, "capabilities" => { "tools" => {} },
            "serverInfo" => { "name" => "stub", "version" => "1.0" } }
        when "tools/list" then page(message.dig("params", "cursor"))
        when "tools/call" then call(message["params"])
        else {}
        end
      end

      def call(params)
        @calls << params
        handler = @tools.fetch(params["name"]).fetch(:handler)
        outcome = handler.call(params["arguments"] || {})
        return outcome if outcome.is_a?(Hash)

        { "content" => [{ "type" => "text", "text" => outcome.to_s }] }
      end

      def page(cursor)
        specs = @tools.map do |name, spec|
          { "name" => name, "description" => spec[:description].to_s,
            "inputSchema" => spec[:schema] || { "type" => "object", "properties" => {} } }
        end
        return { "tools" => specs } unless @page_size

        start = cursor.to_i
        slice = specs[start, @page_size] || []
        result = { "tools" => slice }
        next_cursor = if @next_cursor
                        @next_cursor.call(cursor)
                      elsif start + @page_size < specs.length
                        (start + @page_size).to_s
                      end
        result["nextCursor"] = next_cursor unless next_cursor.nil?
        result
      end

      def respond(socket, id, result, method:, headers: {})
        payload = { "jsonrpc" => "2.0", "id" => id, "result" => result }
        return @stub.respond_json(socket, payload, headers: headers) unless @sse

        head = ["HTTP/1.1 200 OK", "Content-Type: text/event-stream",
                "Transfer-Encoding: chunked", *headers.map { |k, v| "#{k}: #{v}" }]
        socket.write("#{head.join("\r\n")}\r\n\r\n")
        @stub.chunk(socket, "data: #{JSON.generate(payload)}\n\n")
        if method == @trailing_after && !@trailed
          @trailed = true
          trailing = @trailing_record ? "#{JSON.generate(@trailing_record)}\n\n" : "x" * 2000
          @stub.chunk(socket, "data: #{trailing}")
        end
        @stub.finish_sse(socket)
      end

      def session_headers(message)
        return {} unless @session && message["method"] == "initialize"

        { "Mcp-Session-Id" => "#{@session}-#{@initializes}" }
      end

      def authorized?(request)
        request[:headers]["authorization"] == "Bearer #{@require_token}"
      end

      def unauthorized(socket)
        challenge = { "WWW-Authenticate" => 'Bearer resource_metadata="stub"' }
        @stub.respond_json(socket, { "error" => "unauthorized" },
                           status: 401, headers: challenge)
        nil
      end

      # One simulated expiry: a session-carrying request 404s once, then the
      # server accepts a fresh initialize.
      def expire?(request)
        return false unless @expire_after && !@expired
        return false unless request[:headers]["mcp-session-id"]
        return false if @served < @expire_after

        @expired = true
      end

      def expire(socket)
        @stub.respond_json(socket, { "error" => "session not found" }, status: 404)
        nil
      end
    end
  end
end
