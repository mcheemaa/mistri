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
  class Transport
    KEEP_ALIVE_SECONDS = 30

    def initialize(origin:, open_timeout: 15, read_timeout: 300, write_timeout: 60)
      @origin = origin.to_s.chomp("/")
      @uri = URI(@origin)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
      @mutex = Mutex.new
      @connection = nil
    end

    # POST and decode a JSON response body. Retries once on a dead idle
    # socket, so it suits idempotent endpoints.
    def post(path, body:, headers: {})
      response = @mutex.synchronize do
        with_retry { connection.request(build_request(path, body, headers)) }
      end
      raise_for_status(response)
      JSON.parse(response.body)
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
      @mutex.synchronize do
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
    end

    def close
      @mutex.synchronize { teardown }
    end

    private

    def read_either(response, &block)
      if response["content-type"].to_s.include?("text/event-stream")
        sse = SSE.new
        response.read_body { |chunk| sse.feed(chunk, &block) }
        sse.finish(&block)
      else
        raw = response.read_body
        block.call(JSON.parse(raw)) unless raw.to_s.strip.empty?
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
      sse = SSE.new
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
      if streaming
        request["Accept"] = "text/event-stream"
        # Net::HTTP silently negotiates gzip, and its inflater buffers the
        # whole stream, delivering "live" events in one burst at the end.
        request["Accept-Encoding"] = "identity"
      end
      headers.each { |key, value| request[key] = value }
      request.body = JSON.generate(body)
      request
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
      @connection ||= Net::HTTP.new(@uri.host, @uri.port).tap do |http|
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @write_timeout
        http.keep_alive_timeout = KEEP_ALIVE_SECONDS
        http.start
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

      klass = error_class(status)
      options = { status: status, body: response.read_body.to_s[0, 500] }
      options[:retry_after] = retry_after(response) if klass == RateLimitError
      raise klass.new(**options)
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
