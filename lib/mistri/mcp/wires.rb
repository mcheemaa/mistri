# frozen_string_literal: true

require "io/wait"
require "json"

module Mistri
  module MCP
    # The two ways an MCP conversation travels. A wire takes one JSON-RPC
    # payload, yields every decoded message the server sends back until the
    # payload's own response arrives, and knows nothing about MCP semantics;
    # the Client owns those.
    module Wires
      # Streamable HTTP: requests POST to one endpoint, responses arrive as
      # JSON or an SSE stream. Sessions and bearer auth live here.
      class Http
        HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
        INVALID_HEADER_VALUE = /[\x00-\x1F\x7F]/n
        RESERVED_HEADERS = %w[host content-length transfer-encoding connection keep-alive
                              proxy-authenticate proxy-authorization proxy-connection te trailer
                              upgrade accept content-type accept-encoding mcp-session-id
                              mcp-protocol-version].freeze
        private_constant :HEADER_NAME, :INVALID_HEADER_VALUE, :RESERVED_HEADERS

        def initialize(url:, token:, headers:, open_timeout:, read_timeout:, allow_non_public:,
                       max_record_bytes: DEFAULT_MAX_RECORD_BYTES)
          uri, resolver = Egress.resolver(url, allow_non_public:, label: "MCP URL",
                                               timeout: open_timeout)
          @path = uri.path.empty? ? "/" : uri.path
          @path = "#{@path}?#{uri.query}" if uri.query
          @transport = Transport.new(origin: Egress.origin(uri), address_resolver: resolver,
                                     open_timeout: open_timeout, read_timeout: read_timeout,
                                     max_record_bytes: max_record_bytes)
          @token = token
          @headers = normalized_headers(headers)
          @session_id = nil
          @protocol_version = nil
        end

        attr_writer :protocol_version

        def call(payload, replayable:, &)
          meta = @transport.post_either(@path, body: payload, headers: request_headers,
                                               replayable: replayable, &)
          capture_session(meta)
          nil
        end

        def notify(payload)
          discard = ->(_record) {}
          @transport.post_either(@path, body: payload, headers: request_headers, &discard)
          nil
        end

        def session? = !@session_id.nil?

        def refreshable? = @token.respond_to?(:call)

        def reset_session
          @session_id = nil
          @protocol_version = nil
        end

        def close = @transport.close

        private

        def normalized_headers(headers)
          headers.each_with_object({}) do |(key, value), copy|
            name = key.to_s
            content = value.to_s
            unless name.ascii_only? && HEADER_NAME.match?(name)
              raise ConfigurationError, "#{name.inspect} is not a valid HTTP header name"
            end
            if RESERVED_HEADERS.include?(name.downcase)
              raise ConfigurationError, "#{name} is managed by the MCP transport"
            end
            if INVALID_HEADER_VALUE.match?(content.b)
              raise ConfigurationError, "#{name} contains invalid control characters"
            end

            copy[name.dup.freeze] = content.dup.freeze
          end.freeze
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
      end

      # Stdio: a spawned child process, one JSON-RPC message per line, with
      # credentials in its environment, as the spec prescribes for local
      # servers. Its stderr stays attached for honest local debugging.
      class Stdio
        READ_SIZE = 16 * 1024
        BLANK_RECORD = /\A[[:space:]]*\z/
        private_constant :READ_SIZE, :BLANK_RECORD

        def initialize(command:, env: {}, read_timeout: 120,
                       max_record_bytes: DEFAULT_MAX_RECORD_BYTES)
          unless max_record_bytes.is_a?(Integer) && max_record_bytes.positive?
            raise ConfigurationError, "max_record_bytes: must be a positive integer"
          end

          @command = Array(command).map(&:to_s)
          @env = env.transform_keys(&:to_s).transform_values(&:to_s)
          @read_timeout = read_timeout
          @max_record_bytes = max_record_bytes
          @pid = nil
        end

        def call(payload, **)
          spawn_server unless @pid
          write(payload)
          loop do
            record = read_record
            yield record
            break if record.is_a?(Hash) && record["id"] == payload[:id]
          end
          nil
        end

        def notify(payload)
          spawn_server unless @pid
          write(payload)
          nil
        end

        def session? = false

        def refreshable? = false

        def reset_session = nil

        def protocol_version=(_version); end

        def close
          if @pid
            [@stdin, @stdout].each { |io| io.close unless io.closed? }
            terminate
            @pid = nil
          end
          @read_buffer&.clear
          nil
        end

        private

        def spawn_server
          child_in, @stdin = IO.pipe
          @stdout, child_out = IO.pipe
          @pid = Process.spawn(@env, *@command, in: child_in, out: child_out)
          @read_buffer = +"".b
          @newline_search_offset = 0
          child_in.close
          child_out.close
        end

        def write(payload)
          @stdin.write("#{JSON.generate(payload)}\n")
          @stdin.flush
        rescue Errno::EPIPE
          raise WireError, "the MCP server closed its input"
        end

        # The spec requires stdout to carry only protocol messages, so a
        # line that is not one is corruption worth failing loudly on.
        def read_record
          deadline = if @read_timeout
                       Process.clock_gettime(Process::CLOCK_MONOTONIC) + @read_timeout
                     end
          loop do
            line = complete_record
            return JSON.parse(line) if line

            oversized_record! if @read_buffer.bytesize > @max_record_bytes
            chunk = read_chunk(deadline)
            return JSON.parse(eof_record) unless chunk

            @read_buffer << chunk
          end
        rescue JSON::ParserError
          raise WireError, "the MCP server wrote non-protocol output on stdout"
        end

        def complete_record
          while (newline = @read_buffer.index("\n", @newline_search_offset))
            oversized_record! if newline > @max_record_bytes
            line = @read_buffer.slice!(0, newline + 1)
            @newline_search_offset = 0
            return line unless BLANK_RECORD.match?(line)
          end
          @newline_search_offset = @read_buffer.bytesize
          nil
        end

        def read_chunk(deadline)
          loop do
            remaining = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
            if remaining && !remaining.positive?
              raise WireError, "timed out waiting for the MCP server"
            end

            ready = @stdout.wait_readable(remaining)
            raise WireError, "timed out waiting for the MCP server" unless ready

            room = @max_record_bytes - @read_buffer.bytesize + 1
            chunk = @stdout.read_nonblock([READ_SIZE, room].min, exception: false)
            return chunk unless chunk == :wait_readable
          end
        end

        def eof_record
          raise WireError, "the MCP server exited" if @read_buffer.empty?

          line = @read_buffer.slice!(0, @read_buffer.bytesize)
          raise WireError, "the MCP server exited" if BLANK_RECORD.match?(line)

          line
        end

        def oversized_record!
          error = ResponseTooLargeError.new(kind: :stdio_record, limit: @max_record_bytes)
          close
          raise error
        end

        def terminate
          Process.kill("TERM", @pid)
          20.times do
            return if Process.waitpid(@pid, Process::WNOHANG)

            sleep(0.05)
          end
          Process.kill("KILL", @pid)
          Process.waitpid(@pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end
  end
end
