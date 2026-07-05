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
        def initialize(url:, token:, headers:, open_timeout:, read_timeout:)
          uri = URI(url)
          @path = uri.path.empty? ? "/" : uri.path
          @path = "#{@path}?#{uri.query}" if uri.query
          @transport = Transport.new(origin: "#{uri.scheme}://#{uri.host}:#{uri.port}",
                                     open_timeout: open_timeout, read_timeout: read_timeout)
          @token = token
          @headers = headers
          @session_id = nil
          @protocol_version = nil
        end

        attr_writer :protocol_version

        def call(payload, &)
          meta = @transport.post_either(@path, body: payload, headers: request_headers, &)
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

        def reset_session = @session_id = nil

        def close = @transport.close

        private

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
        def initialize(command:, env: {}, read_timeout: 120)
          @command = Array(command).map(&:to_s)
          @env = env.transform_keys(&:to_s).transform_values(&:to_s)
          @read_timeout = read_timeout
          @pid = nil
        end

        def call(payload)
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
          return unless @pid

          [@stdin, @stdout].each { |io| io.close unless io.closed? }
          terminate
          @pid = nil
        end

        private

        def spawn_server
          child_in, @stdin = IO.pipe
          @stdout, child_out = IO.pipe
          @pid = Process.spawn(@env, *@command, in: child_in, out: child_out)
          child_in.close
          child_out.close
        end

        def write(payload)
          @stdin.write("#{JSON.generate(payload)}\n")
          @stdin.flush
        rescue Errno::EPIPE
          raise Error, "the MCP server closed its input"
        end

        # The spec requires stdout to carry only protocol messages, so a
        # line that is not one is corruption worth failing loudly on.
        def read_record
          loop do
            ready = @stdout.wait_readable(@read_timeout)
            raise Error, "timed out waiting for the MCP server" unless ready

            line = @stdout.gets
            raise Error, "the MCP server exited" if line.nil?
            next if line.strip.empty?

            return JSON.parse(line)
          end
        rescue JSON::ParserError
          raise Error, "the MCP server wrote non-protocol output on stdout"
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
