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
      TIMED_OUT = "timed out waiting for the MCP server"
      private_constant :TIMED_OUT

      # Streamable HTTP: requests POST to one endpoint, responses arrive as
      # JSON or an SSE stream. Sessions and bearer auth live here.
      class Http
        HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
        INVALID_HEADER_VALUE = /[\x00-\x1F\x7F]/n
        RESERVED_HEADERS = %w[host content-length transfer-encoding connection keep-alive
                              proxy-authenticate proxy-authorization proxy-connection te trailer
                              upgrade accept content-type accept-encoding mcp-session-id
                              mcp-protocol-version last-event-id].freeze
        # Seconds before a stream that ended early is asked for again, when
        # the server named none.
        RECONNECT_WAIT = 1
        # Seconds a message said aside may take.
        ASIDE_TIMEOUT = 5
        private_constant :HEADER_NAME, :INVALID_HEADER_VALUE, :RESERVED_HEADERS, :RECONNECT_WAIT,
                         :ASIDE_TIMEOUT

        # The decoder of one stream, which also keeps what a client needs to
        # go back to it: the id of the last whole event, and the wait the
        # server asked for.
        class Events < SSE
          attr_reader :last_event_id, :retry_after

          private

          # An id counts when its event ends, at the blank line.
          def decode(line, &)
            if line.empty?
              @last_event_id = @event_id if @event_id
            elsif line.start_with?("id:")
              id = line.delete_prefix("id:").delete_prefix(" ")
              @event_id = id unless id.include?("\0")
            elsif line.start_with?("retry:")
              wait = line.delete_prefix("retry:").strip
              @retry_after = wait.to_i / 1000.0 if wait.match?(/\A\d+\z/)
            else
              super
            end
          end
        end
        private_constant :Events

        def initialize(url:, token:, headers:, open_timeout:, read_timeout:, allow_non_public:,
                       max_record_bytes: DEFAULT_MAX_RECORD_BYTES)
          uri, resolver = Egress.resolver(url, allow_non_public:, label: "MCP URL",
                                               timeout: open_timeout)
          @path = uri.path.empty? ? "/" : uri.path
          @path = "#{@path}?#{uri.query}" if uri.query
          @dial = lambda do |open, read|
            Transport.new(origin: Egress.origin(uri), address_resolver: resolver,
                          open_timeout: open, read_timeout: read,
                          max_record_bytes: max_record_bytes)
          end
          @transport = @dial.call(open_timeout, read_timeout)
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @max_record_bytes = max_record_bytes
          @token = token
          @headers = normalized_headers(headers)
          @session_id = nil
          @protocol_version = nil
        end

        attr_writer :protocol_version

        # Reads until the block returns what it took for the answer.
        def call(payload, replayable:)
          @reading = true
          answered = false
          took = ->(record) { answered ||= yield(record) }
          events = Events.new(max_record_bytes: @max_record_bytes)
          capture_session(post(@transport, payload, replayable: replayable, events: events, &took))
          resume(events, &took) unless answered
          nil
        ensure
          @reading = false
        end

        # A reply to the server's own request leaves while the response of a
        # call is read, and a cancel leaves when a call was given up. Neither
        # may hold the caller, so both go out on a second connection, which
        # waits ASIDE_TIMEOUT at most.
        def notify(payload, wait: nil)
          post(@reading || wait ? aside : @transport, payload) { |_record| nil }
          nil
        end

        def open? = true

        def session? = !@session_id.nil?

        def refreshable? = @token.respond_to?(:call)

        def reset_session
          @session_id = nil
          @protocol_version = nil
        end

        # The spec asks a client that is done with a session to say so. The
        # server may refuse, and the session ends for this client either way.
        # The token is the one last sent: a close does not wait for a refresh.
        def end_session
          aside.delete(@path, headers: request_headers(fresh: false)) if @session_id
        rescue Mistri::Error
          nil
        ensure
          reset_session
        end

        def close
          @aside&.close
          @transport.close
        end

        private

        # The headers are resolved first, so an error from the host's token
        # callable is not taken for the server's answer. A server that was too
        # slow is kept, as a slow stdio server is. A refusal keeps its class,
        # status and body, and its message names an MCP server, not a provider.
        def post(transport, payload, **, &)
          headers = request_headers
          begin
            transport.post_either(@path, body: payload, headers: headers, **, &)
          rescue ProviderError => e
            raise WireTimeout, TIMED_OUT if slow?(e)
            raise unless e.status

            raise e.exception(refusal(e))
          end
        end

        # A server may end the stream of a call before the answer and expect
        # the client back for it: once, after the wait the server named, from
        # the last event it sent. A failure here leaves the call unanswered,
        # and never sends the call again.
        def resume(events, &)
          wait = events.retry_after || RECONNECT_WAIT
          return if events.last_event_id.nil? || (@read_timeout && wait > @read_timeout)

          sleep(wait)
          headers = request_headers.merge("Last-Event-ID" => events.last_event_id)
          @transport.get_either(@path, headers: headers,
                                       events: Events.new(max_record_bytes: @max_record_bytes), &)
          nil
        rescue ProviderError => e
          raise WireTimeout, TIMED_OUT if slow?(e)

          nil
        end

        def aside
          @aside ||= @dial.call([@open_timeout, ASIDE_TIMEOUT].compact.min, ASIDE_TIMEOUT)
        end

        def slow?(error)
          error.cause.is_a?(Timeout::Error) && !error.cause.is_a?(Net::OpenTimeout)
        end

        def refusal(error)
          return "the MCP server did not authorize the request" if error.is_a?(AuthenticationError)

          said = begin
            JSON.parse(error.body.to_s).dig("error", "message")
          rescue JSON::ParserError, TypeError, NoMethodError
            nil
          end
          detail = ": #{said[0, 200]}" if said.is_a?(String) && !said.empty?
          "the MCP server answered HTTP #{error.status}#{detail}"
        end

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

        def request_headers(fresh: true)
          @authorization = "Bearer #{resolve_token}" if @token && fresh
          headers = { "Accept" => "application/json, text/event-stream" }
          headers.merge!(@headers)
          headers["Authorization"] = @authorization if @authorization
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
      # servers. It is third-party code, so it starts from INHERITED_ENV and
      # the client's env, not the host's environment. Its stderr stays attached
      # for honest local debugging.
      class Stdio
        READ_SIZE = 16 * 1024
        WRITE_SIZE = 64 * 1024
        BLANK_RECORD = /\A[[:space:]]*\z/
        # Seconds a server gets to end by itself once its input is closed, and
        # then to end after SIGTERM.
        EXIT_WAIT = 0.5
        TERM_WAIT = 1
        # What a runtime needs to start and behave: identity and programs,
        # RubyGems paths, locale and temp files, CA bundles. A name that can
        # carry a credential stays out, proxy settings included.
        INHERITED_ENV = %w[
          HOME USER LOGNAME SHELL PATH TERM
          GEM_HOME GEM_PATH
          LANG LC_ALL LC_CTYPE TZ TMPDIR
          SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE CURL_CA_BUNDLE
        ].freeze
        private_constant :READ_SIZE, :WRITE_SIZE, :BLANK_RECORD, :EXIT_WAIT, :TERM_WAIT,
                         :INHERITED_ENV

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
          @cut_write = false
        end

        # Reads until the block returns what it took for the answer.
        def call(payload, **)
          start
          write(payload, @read_timeout)
          loop { break if yield(read_record) }
          nil
        end

        # wait is the seconds the server may take to read the message. A
        # server is never started to be sent one.
        def notify(payload, wait: @read_timeout)
          write(payload, wait) if open?
          nil
        end

        # False once the server this wire spoke to is gone or cannot be
        # written to, so the client knows to do the handshake again.
        def open? = !@pid.nil? && !@cut_write

        def session? = false

        def refreshable? = false

        def reset_session = nil

        def end_session = nil

        def protocol_version=(_version); end

        def close
          if @pid
            [@stdin, @stdout].each { |io| io.close unless io.closed? }
            terminate
            @pid = nil
          end
          @read_buffer&.clear
          @cut_write = false
          nil
        end

        private

        # A write that was cut short left half a message in the server's input,
        # and the next message would be read as its end.
        def start
          close if @cut_write
          spawn_server unless @pid
        end

        def spawn_server
          child_in, @stdin = IO.pipe
          @stdout, child_out = IO.pipe
          env = ENV.slice(*INHERITED_ENV).merge(@env)
          @pid = Process.spawn(env, *@command,
                               in: child_in, out: child_out, unsetenv_others: true)
          @read_buffer = +"".b
          @newline_search_offset = 0
          child_in.close
          child_out.close
        end

        # Written without blocking, so a server that has stopped reading holds
        # the caller only until the deadline.
        def write(payload, wait)
          line = "#{JSON.generate(payload)}\n".b
          deadline = wait && (clock + wait)
          sent = 0
          while sent < line.bytesize
            @cut_write = true
            count = @stdin.write_nonblock(line.byteslice(sent, WRITE_SIZE), exception: false)
            if count == :wait_writable
              @cut_write = sent.positive?
              raise WireTimeout, TIMED_OUT unless @stdin.wait_writable(remaining(deadline))
            else
              sent += count
            end
          end
          @cut_write = false
        rescue Errno::EPIPE
          raise WireError, "the MCP server closed its input"
        end

        # stdout carries one message a line. A line that is not JSON is
        # skipped and written to standard error, where the server's own
        # standard error goes, and the wait for the message goes on.
        def read_record
          deadline = @read_timeout && (clock + @read_timeout)
          loop do
            line = next_line(deadline)
            return JSON.parse(line)
          rescue JSON::ParserError
            text = line.byteslice(0, 200).force_encoding(Encoding::UTF_8).scrub.strip
            warn("mistri: the MCP server wrote a line that is not JSON: #{text.inspect}")
          end
        end

        def next_line(deadline)
          loop do
            line = complete_record
            return line if line

            oversized_record! if @read_buffer.bytesize > @max_record_bytes
            chunk = read_chunk(deadline)
            return eof_record unless chunk

            @read_buffer << chunk
          end
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
            raise WireTimeout, TIMED_OUT unless @stdout.wait_readable(remaining(deadline))

            room = @max_record_bytes - @read_buffer.bytesize + 1
            chunk = @stdout.read_nonblock([READ_SIZE, room].min, exception: false)
            return chunk unless chunk == :wait_readable
          end
        end

        def remaining(deadline)
          return unless deadline

          left = deadline - clock
          raise WireTimeout, TIMED_OUT unless left.positive?

          left
        end

        def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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
          return if exited?(EXIT_WAIT)

          Process.kill("TERM", @pid)
          return if exited?(TERM_WAIT)

          Process.kill("KILL", @pid)
          Process.waitpid(@pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end

        def exited?(seconds)
          deadline = clock + seconds
          until Process.waitpid(@pid, Process::WNOHANG)
            return false if clock >= deadline

            sleep(0.01)
          end
          true
        end
      end
    end
  end
end
