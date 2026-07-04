# frozen_string_literal: true

require "socket"

module Mistri
  module Test
    # A minimal in-process HTTP server for transport tests: real sockets, real
    # keep-alive, scripted responses. Each scripted entry handles one request
    # on whatever connection it arrives; `accepts` counts distinct connections,
    # which is how tests observe reuse and reconnects.
    class StubServer
      attr_reader :accepts, :requests

      def initialize(&script)
        @script = script
        @accepts = 0
        @requests = []
        @handlers = []
        @server = TCPServer.new("127.0.0.1", 0)
        @thread = Thread.new { serve }
      end

      def origin = "http://127.0.0.1:#{@server.addr[1]}"

      def stop
        @server.close
        [@thread, *@handlers].each do |thread|
          thread.kill
          thread.join
        end
      end

      # Response helpers for scripts.

      def respond_json(socket, body, status: 200, headers: {})
        payload = body.is_a?(String) ? body : JSON.generate(body)
        head = ["HTTP/1.1 #{status} X", "Content-Type: application/json",
                "Content-Length: #{payload.bytesize}",
                *headers.map { |k, v| "#{k}: #{v}" }]
        socket.write("#{head.join("\r\n")}\r\n\r\n#{payload}")
      end

      def start_sse(socket)
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                     "Transfer-Encoding: chunked\r\n\r\n")
      end

      def sse_data(socket, hash)
        chunk(socket, "data: #{JSON.generate(hash)}\n\n")
      end

      def finish_sse(socket)
        socket.write("0\r\n\r\n")
      end

      def chunk(socket, data)
        socket.write("#{data.bytesize.to_s(16)}\r\n#{data}\r\n")
      end

      private

      def serve
        loop do
          socket = @server.accept
          @accepts += 1
          @handlers << Thread.new { handle(socket) }
        end
      rescue IOError
        nil
      end

      def handle(socket)
        while (request = read_request(socket))
          @requests << request
          break if @script.call(socket, request) == :close
        end
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError
        nil
      ensure
        socket.close unless socket.closed?
      end

      def read_request(socket)
        line = socket.gets or return nil
        headers = {}
        while (header = socket.gets) && header != "\r\n"
          key, value = header.split(": ", 2)
          headers[key.downcase] = value.to_s.strip
        end
        body = socket.read(headers["content-length"].to_i)
        { line: line, headers: headers, body: body }
      end
    end
  end
end
