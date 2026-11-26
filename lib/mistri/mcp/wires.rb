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
      # The first revision with no handshake and no session: each request
      # carries its own version.
      STATELESS_SINCE = "2026-07-28"
      private_constant :TIMED_OUT, :STATELESS_SINCE

      # Streamable HTTP: requests POST to one endpoint, responses arrive as
      # JSON or an SSE stream. Sessions and bearer auth live here.
      class Http
        HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
        INVALID_HEADER_VALUE = /[\x00-\x1F\x7F]/n
        RESERVED_HEADERS = %w[host content-length transfer-encoding connection keep-alive
                              proxy-authenticate proxy-authorization proxy-connection te trailer
                              upgrade accept content-type accept-encoding mcp-session-id
                              mcp-protocol-version last-event-id mcp-method mcp-name].freeze
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
              @event_id = id unless id.match?(/[\0\r]/)
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

        # Reads until the block returns what it took for the answer. mirror is
        # the schema of the tool a call is for.
        def call(payload, replayable:, mirror: nil, **)
          @reading = true
          answered = false
          took = ->(record) { answered = yield(record) || answered }
          events = Events.new(max_record_bytes: @max_record_bytes)
          headers = unsent_headers
          headers.merge!(repeated(payload, mirror)) if stateless?
          meta = post(@transport, payload, headers, replayable: replayable, events: events, &took)
          return if stateless?

          capture_session(meta)
          resume(events, &took) unless answered
          nil
        ensure
          @reading = false
        end

        # A reply to the server's own request leaves while the response of a
        # call is read, on a second connection, because the first is taken.
        def notify(payload)
          post(@reading ? aside : @transport, payload) { |_record| nil }
          nil
        end

        # A call that was given up is cancelled with a notification, on the
        # second connection, which waits ASIDE_TIMEOUT at most. Since
        # 2026-07-28 the closed stream of the call is the cancel.
        def cancel(payload)
          post(aside, payload) { |_record| nil } unless stateless?
          nil
        end

        def open? = true

        # A remote server is not this client's to end.
        def restartable? = false

        # Since 2026-07-28 a client repeats parts of a request in its headers.
        def mirrors? = stateless?

        # An HTTP server that takes long to answer is slow, not old.
        def probe_wait = nil

        def session? = !@session_id.nil?

        def refreshable? = @token.respond_to?(:call)

        # The server refused the token last sent. A callable that takes
        # refused: is given it the next time it is asked, so it can tell a
        # token it should replace from one another request already replaced.
        def token_refused
          @refused = @authorization&.delete_prefix("Bearer ")
        end

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

        # The headers of a request, resolved before anything of it is written,
        # so what the host's token callable raises here is tagged NotSent.
        def unsent_headers
          request_headers
        rescue StandardError => e
          raise e.clone(freeze: false).extend(NotSent)
        end

        # A reply, a notice and a cancel go out with the token last sent, so no
        # code of the host runs for them. A server that was too slow is kept,
        # as a slow stdio server is. A refusal keeps its class, status and
        # body, and its message names an MCP server, not a provider.
        def post(transport, payload, headers = nil, **, &)
          headers ||= request_headers(fresh: false)
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

        def stateless? = @protocol_version.to_s >= STATELESS_SINCE

        # The method of a request, the name it is for, and each parameter the
        # tool's schema marks.
        def repeated(payload, mirror)
          params = payload[:params] || {}
          name = params[:name] || params[:uri]
          headers = { "Mcp-Method" => payload[:method].to_s }
          headers["Mcp-Name"] = Mirror.value(name.to_s) if name
          headers.merge!(Mirror.headers(mirror, params[:arguments])) if mirror
          headers
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
          return @token unless @token.respond_to?(:call)

          refused = @refused
          @refused = nil
          refused && names_refused? ? @token.call(refused: refused) : @token.call
        end

        def names_refused?
          callable = @token.respond_to?(:parameters) ? @token : @token.method(:call)
          callable.parameters.any? do |kind, name|
            kind == :keyrest || (%i[key keyreq].include?(kind) && name == :refused)
          end
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
        # Seconds a server gets to say which revisions it speaks. An older
        # server may not answer a request it does not know at all.
        PROBE_WAIT = 5
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
        private_constant :READ_SIZE, :WRITE_SIZE, :PROBE_WAIT, :BLANK_RECORD, :EXIT_WAIT,
                         :TERM_WAIT, :INHERITED_ENV

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

        # Reads until the block returns what it took for the answer. wait
        # replaces the read timeout for this one request.
        def call(payload, wait: nil, **)
          start
          write(payload, wait || @read_timeout)
          loop { break if yield(read_record(wait || @read_timeout)) }
          nil
        end

        # wait is the seconds the server may take to read the message. A
        # server is never started to be sent one.
        def notify(payload, wait: @read_timeout)
          write(payload, wait) if open?
          nil
        end

        # A call that was given up is cancelled with a notification, which
        # does not wait for a server that has stopped reading.
        def cancel(payload) = notify(payload, wait: 0)

        # False once the server this wire spoke to is gone or cannot be
        # written to, so the client knows to do the handshake again. A close
        # that was ended early leaves a server whose input is closed.
        def open? = !@pid.nil? && !@cut_write && !@stdin.closed?

        # This wire started the server, so it can end it and start another.
        def restartable? = true

        def mirrors? = false

        def probe_wait = [@read_timeout, PROBE_WAIT].compact.min

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
          close if @pid && !open?
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
        def read_record(wait = @read_timeout)
          deadline = wait && (clock + wait)
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
