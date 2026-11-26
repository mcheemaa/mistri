# frozen_string_literal: true

require "json"
require_relative "stub_server"

module Mistri
  module Test
    # An MCP server over Streamable HTTP whose tools are scripts. A tool is a
    # lambda given this server, the socket and the id of its call, and writes
    # the response itself: a stream that stays open, one that ends early, a
    # request of its own. A script that returns :close drops the connection.
    class McpScriptedServer
      # discover: is what the server answers server/discover with: a result,
      # or a lambda given this server, the socket and the id. Without it the
      # server is an older one that does not know the request.
      # capabilities: is what the handshake declares, and resources: maps a
      # URI to the contents that resources/read returns for it.
      def initialize(tools: {}, session: "s1", on_get: nil, delete_status: 200, list_wait: 0,
                     discover: nil, listed: [], capabilities: {}, resources: {})
        @tools = tools
        @capabilities = capabilities
        @resources = resources
        @discover = discover
        @listed = listed
        @session = session
        @on_get = on_get
        @delete_status = delete_status
        @list_wait = list_wait
        @replies = Queue.new
        @stub = StubServer.new { |socket, request| route(socket, request) }
      end

      attr_writer :list_wait

      # The id of the call a tool is running for.
      attr_reader :calling

      def url = "#{@stub.origin}/mcp"
      def stop = @stub.stop
      def accepts = @stub.accepts

      def requests(verb) = @stub.requests.select { |request| request[:line].start_with?(verb) }

      # Every message the client posted.
      def posted = requests("POST").map { |request| JSON.parse(request[:body]) }

      def sent(method) = posted.select { |message| message["method"] == method }

      # The next reply the client posted to a request of this server.
      def reply(seconds = 2) = @replies.pop(timeout: seconds)

      def answer(id, text)
        { "jsonrpc" => "2.0", "id" => id,
          "result" => { "content" => [{ "type" => "text", "text" => text }] } }
      end

      def json(socket, body, status: 200, headers: {})
        @stub.respond_json(socket, body, status: status, headers: headers)
      end

      def open(socket) = @stub.start_sse(socket)
      def event(socket, message) = @stub.sse_data(socket, message)
      def raw(socket, text) = @stub.chunk(socket, text)
      def finish(socket) = @stub.finish_sse(socket)

      private

      def route(socket, request)
        return json(socket, "", status: @delete_status) if request[:line].start_with?("DELETE")
        return came_back(socket, request) if request[:line].start_with?("GET")

        message = JSON.parse(request[:body])
        return said(socket, message) unless message["method"] && message.key?("id")

        case message["method"]
        when "initialize" then json(socket, handshake(message["id"]), headers: session_header)
        when "tools/list"
          sleep(@list_wait)
          result(socket, message["id"], { "tools" => @listed })
        when "server/discover" then discover(socket, message["id"])
        when "resources/read" then read(socket, message)
        when "tools/call"
          @calling = message["id"]
          @tools.fetch(message.dig("params", "name")).call(self, socket, @calling)
        else refuse(socket, message["id"])
        end
      end

      def result(socket, id, result)
        json(socket, { "jsonrpc" => "2.0", "id" => id, "result" => result })
      end

      def refuse(socket, id, code: -32_601, message: "Method not found", data: nil, status: 200)
        error = { "code" => code, "message" => message, "data" => data }.compact
        json(socket, { "jsonrpc" => "2.0", "id" => id, "error" => error }, status: status)
      end

      def read(socket, message)
        contents = @resources[message.dig("params", "uri")]
        return result(socket, message["id"], contents) if contents && !contents.is_a?(Array)
        return result(socket, message["id"], { "contents" => contents }) if contents

        refuse(socket, message["id"], code: -32_602, message: "Resource not found")
      end

      def discover(socket, id)
        return refuse(socket, id) unless @discover
        return @discover.call(self, socket, id) if @discover.respond_to?(:call)

        result(socket, id, @discover)
      end

      public :result, :refuse

      def came_back(socket, request)
        return json(socket, "", status: 405) unless @on_get

        @on_get.call(self, socket, request)
      end

      def said(socket, message)
        @replies << message unless message["method"]
        json(socket, "", status: 202)
      end

      def session_header = @session ? { "Mcp-Session-Id" => @session } : {}

      def handshake(id)
        { "jsonrpc" => "2.0", "id" => id,
          "result" => { "protocolVersion" => "2025-11-25", "capabilities" => @capabilities,
                        "serverInfo" => { "name" => "scripted", "version" => "1" } } }
      end
    end
  end
end
