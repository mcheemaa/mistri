# frozen_string_literal: true

require "net/http"
require "openssl"
require "json"
require "uri"

module Mistri
  # HTTP for one provider origin, held open across the turns of a run: a
  # multi-turn agent pays the TCP and TLS handshake once, not per turn. Not
  # shareable across threads; a mutex serializes accidental concurrent use onto
  # the single socket, and re-entering from a streaming callback raises
  # ThreadError.
  #
  # Streaming reads abort two ways: cooperatively between fragments, and hard,
  # by closing the socket from the abort signal's callback, so a stalled read
  # stops immediately instead of waiting out the read timeout.
  # An address_resolver supplies a fresh validated set for each connection
  # cycle; candidates are tried before the request is sent while the original
  # hostname still owns Host, SNI, and TLS validation.
  # JSON bodies and individual SSE lines share one configurable byte ceiling;
  # a stream may contain any number of individually safe lines.
  class Transport
    KEEP_ALIVE_SECONDS = 30
    ERROR_PREVIEW_BYTES = 500
    BLANK_BODY = /\A[[:space:]]*\z/
    CONNECT_ERRORS = [IOError, SocketError, SystemCallError, Timeout::Error,
                      Net::HTTPBadResponse, OpenSSL::SSL::SSLError].freeze

    # Net::HTTP reconnects expired keep-alives internally. Resolving inside
    # connect makes every MCP connection cycle cross the egress boundary.
    class ResolvedHTTP < Net::HTTP
      attr_writer :address_resolver

      private

      def connect
        addresses = Array(@address_resolver.call)
        raise ConfigurationError, "address_resolver returned no addresses" if addresses.empty?

        original_timeout = @open_timeout
        deadline = if original_timeout
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) + original_timeout
                   end
        failure = nil
        addresses.each do |address|
          remaining = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
          break if remaining && !remaining.positive?

          @ipaddr = address
          @open_timeout = remaining if remaining
          begin
            return super
          rescue *CONNECT_ERRORS => e
            failure = e
          end
        end
        raise failure || Net::OpenTimeout.new("all approved addresses timed out")
      ensure
        @open_timeout = original_timeout if original_timeout
      end
    end
    private_constant :ResolvedHTTP, :CONNECT_ERRORS, :BLANK_BODY

    def initialize(origin:, open_timeout: 15, read_timeout: 300, write_timeout: 60,
                   address_resolver: nil, max_record_bytes: DEFAULT_MAX_RECORD_BYTES)
      unless max_record_bytes.is_a?(Integer) && max_record_bytes.positive?
        raise ConfigurationError, "max_record_bytes: must be a positive integer"
      end

      @origin = origin.to_s.chomp("/")
      @uri = URI(@origin)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
      @address_resolver = address_resolver
      @max_record_bytes = max_record_bytes
      @mutex = Mutex.new
      @connection = nil
    end

    # POST and decode a JSON response body. Retries once on a dead idle
    # socket, so it suits idempotent endpoints.
    def post(path, body:, headers: {})
      @mutex.synchronize do
        with_retry do
          parsed = nil
          connection.request(build_request(path, body, headers)) do |response|
            raise_for_status(response)
            parsed = JSON.parse(read_json_body(response))
          end
          parsed
        end
      rescue ResponseTooLargeError, ResponseTooComplexError, ProviderError, JSON::ParserError
        teardown
        raise
      end
    end

    # POST and stream the SSE response, yielding each decoded data record.
    # Returns :aborted when the signal cancelled the stream, else nil.
    def stream_post(path, body:, headers: {}, signal: nil, &block)
      return :aborted if signal&.aborted?

      @mutex.synchronize { stream_locked(path, body, headers, signal, &block) }
    end

    # POST for Streamable-HTTP endpoints (the MCP shape) that answer either
    # a JSON body or an SSE stream: yields each JSON record either way and
    # returns the response headers, downcased. A replayable request retries
    # once when a dead idle socket fails before any response starts.
    def post_either(path, body:, headers: {}, replayable: true, &block)
      @mutex.synchronize { post_either_locked(path, body, headers, replayable, &block) }
    end

    def close
      @mutex.synchronize { teardown }
    end

    private

    def post_either_locked(path, body, headers, replayable, &block)
      retried = false
      begin
        started = false
        response_headers = nil
        connection.request(build_request(path, body, headers, streaming: true)) do |response|
          started = true
          raise_for_status(response)
          response_headers = response.to_hash.transform_values(&:first)
          read_either(response, &block)
        end
        response_headers
      rescue ResponseTooLargeError, ResponseTooComplexError, ProviderError
        teardown
        raise
      rescue IOError, SocketError, SystemCallError, Timeout::Error, JSON::ParserError,
             Net::HTTPBadResponse, OpenSSL::SSL::SSLError => e
        teardown
        unless replayable
          raise AmbiguousDeliveryError, "#{AmbiguousDeliveryError.default_message}: #{e.message}"
        end
        if started || retried || e.is_a?(Timeout::Error)
          raise ProviderError, "connection failed: #{e.message}"
        end

        retried = true
        retry
      end
    end

    def read_either(response, &block)
      if response["content-type"].to_s.include?("text/event-stream")
        sse = SSE.new(max_record_bytes: @max_record_bytes)
        response.read_body { |chunk| sse.feed(chunk, &block) }
        sse.finish(&block)
      else
        raw = read_json_body(response)
        block.call(JSON.parse(raw)) unless BLANK_BODY.match?(raw)
      end
    end

    def stream_locked(path, body, headers, signal, &block)
      retried = false
      begin
        started = false
        aborted = false
        conn = connection
        # The closer targets this turn's connection, so an abort that fires
        # late, after the turn already finished, cannot touch a successor's
        # socket.
        closer = signal&.on_abort { quietly_finish(conn) }
        begin
          conn.request(build_request(path, body, headers, streaming: true)) do |response|
            started = true
            raise_for_status(response)
            aborted = read_stream(response, signal, &block)
          end
        ensure
          signal&.remove_callback(closer) if closer
        end
        # An abort mid-body leaves unread bytes on the socket; drop it rather
        # than let the next request read stale frames.
        teardown if aborted
        aborted ? :aborted : nil
      rescue EventDelivery::Failure, ResponseTooLargeError, ResponseTooComplexError, ProviderError
        teardown
        raise
      rescue IOError, SocketError, SystemCallError, Timeout::Error => e
        teardown
        return :aborted if signal&.aborted?

        # A dead idle keep-alive socket fails before the response starts and
        # retries safely. A drop after events flowed must not replay the turn.
        if !started && !retried
          retried = true
          retry
        end
        raise ProviderError, "connection lost mid-stream: #{e.message}"
      end
    end

    def read_stream(response, signal, &block)
      sse = SSE.new(max_record_bytes: @max_record_bytes)
      aborted = false
      response.read_body do |fragment|
        if signal&.aborted?
          aborted = true
          break
        end
        sse.feed(fragment, &block)
      end
      sse.finish(&block) unless aborted
      aborted
    end

    def build_request(path, body, headers, streaming: false)
      request = Net::HTTP::Post.new(URI("#{@origin}#{path}"))
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream" if streaming
      headers.each { |key, value| request[key] = value }
      # Identity keeps the byte ceiling meaningful before an untrusted
      # compressed expansion and preserves immediate SSE delivery.
      request["Accept-Encoding"] = "identity"
      request.body = JSON.generate(body)
      request
    end

    def read_json_body(response)
      declared = response["content-length"]
      if declared&.match?(/\A\d+\z/) && declared.to_i > @max_record_bytes
        raise ResponseTooLargeError.new(kind: :json_body, limit: @max_record_bytes)
      end

      body = +""
      response.read_body do |fragment|
        if body.bytesize + fragment.bytesize > @max_record_bytes
          raise ResponseTooLargeError.new(kind: :json_body, limit: @max_record_bytes)
        end

        body << fragment
      end
      body
    end

    def with_retry
      attempted = false
      begin
        yield
      rescue Timeout::Error => e
        # The server may already be executing the request; a replay risks
        # running it twice.
        teardown
        raise ProviderError, "request timed out: #{e.message}"
      rescue IOError, SocketError, SystemCallError => e
        teardown
        raise ProviderError, "connection failed: #{e.message}" if attempted

        attempted = true
        retry
      end
    end

    def connection
      @connection ||= begin
        http = if @address_resolver
                 ResolvedHTTP.new(@uri.hostname, @uri.port, nil).tap do |resolved|
                   resolved.address_resolver = @address_resolver
                 end
               else
                 Net::HTTP.new(@uri.hostname, @uri.port)
               end
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @write_timeout
        http.keep_alive_timeout = KEEP_ALIVE_SECONDS
        http.start
        http
      end
    end

    def teardown
      @connection&.finish
    rescue IOError
      nil
    ensure
      @connection = nil
    end

    def quietly_finish(conn)
      conn.finish
    rescue IOError
      nil
    end

    def raise_for_status(response)
      status = response.code.to_i
      return if (200..299).cover?(status)

      preview = +""
      response.read_body do |fragment|
        remaining = ERROR_PREVIEW_BYTES - preview.bytesize
        preview << fragment.byteslice(0, remaining) if remaining.positive?
        raise status_error(response, status, preview) if preview.bytesize >= ERROR_PREVIEW_BYTES
      end
      raise status_error(response, status, preview)
    end

    def status_error(response, status, preview)
      klass = error_class(status)
      body = preview.dup.force_encoding(Encoding::UTF_8).scrub("?")
      options = { status: status, body: body }
      options[:retry_after] = retry_after(response) if klass == RateLimitError
      klass.new(**options)
    end

    def error_class(status)
      case status
      when 401, 403 then AuthenticationError
      when 429 then RateLimitError
      when 529 then OverloadedError
      when 500..599 then ServerError
      else ProviderError
      end
    end

    def retry_after(response)
      value = response["retry-after"]
      value&.match?(/\A\d+(\.\d+)?\z/) ? value.to_f : nil
    end
  end
end
