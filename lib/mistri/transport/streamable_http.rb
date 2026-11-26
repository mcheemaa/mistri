# frozen_string_literal: true

module Mistri
  class Transport
    # Requests to a Streamable HTTP endpoint, the MCP shape: it answers a POST
    # with a JSON body or with an SSE stream, a GET with a stream, and a
    # DELETE with a status.
    module StreamableHTTP
      # Seconds a stream gets to end once it has given its answer. A stream
      # read to its end keeps its connection. Most end within a few
      # milliseconds, and one that stays open would hold the caller.
      LINGER = 0.1
      private_constant :LINGER

      # POST for Streamable-HTTP endpoints (the MCP shape) that answer either
      # a JSON body or an SSE stream: yields each JSON record either way and
      # returns the response headers, downcased. The block returns true once
      # it has the answer the request was sent for. A stream is read a moment
      # more then, so that its connection can be kept, and left if it stays
      # open. events: is the decoder a stream is read with. A replayable
      # request retries once when a dead idle socket fails before any response
      # starts.
      def post_either(path, body:, headers: {}, replayable: true, events: nil, &block)
        @mutex.synchronize do
          either(replayable, events, block) { build_request(path, body, headers, streaming: true) }
        end
      end

      # GET for the same endpoints, which answer it with an SSE stream. An MCP
      # client goes back this way to a response whose stream ended early.
      def get_either(path, headers: {}, events: nil, &block)
        @mutex.synchronize do
          either(true, events, block) { bodiless(Net::HTTP::Get, path, headers) }
        end
      end

      # DELETE with no body. Only the status of the response matters.
      def delete(path, headers: {})
        @mutex.synchronize do
          with_retry do
            read_whole do
              connection.request(bodiless(Net::HTTP::Delete, path, headers)) do |response|
                raise_for_status(response)
              end
            end
          end
        rescue ProviderError
          teardown
          raise
        end
        nil
      end

      private

      # The block builds the request, again for a retry. A failure of the
      # connection after the answer does not fail the request.
      def either(replayable, events, block)
        retried = false
        begin
          started = false
          answered = false
          response_headers = nil
          catch(:left) do
            read_whole do
              connection.request(yield) do |response|
                started = true
                raise_for_status(response)
                response_headers = response.to_hash.transform_values(&:first)
                read_either(response, events) { |record| answered ||= block.call(record) }
              end
            end
          end
          response_headers
        rescue ResponseTooLargeError, ResponseTooComplexError, ProviderError
          teardown
          raise
        rescue IOError, SocketError, SystemCallError, Timeout::Error, JSON::ParserError,
               Net::HTTPBadResponse, OpenSSL::SSL::SSLError => e
          teardown
          return response_headers if answered

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

      def read_either(response, events, &)
        if response["content-type"].to_s.include?("text/event-stream")
          read_events(response, events || SSE.new(max_record_bytes: @max_record_bytes), &)
        else
          raw = read_json_body(response)
          yield JSON.parse(raw) unless BLANK_BODY.match?(raw)
        end
      end

      # Net::HTTP's read timeout starts again with every byte, so a comment a
      # second would hold a request for ever. The wait is for a message, and
      # after the answer for the end of the stream. Whenever bytes arrive, the
      # socket's timeout is set to what is left of that wait.
      def read_events(response, sse, &block)
        heard = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        answered = nil
        response.read_body do |chunk|
          sse.feed(chunk) do |record|
            heard = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            answered ||= heard if block.call(record)
          end
          limit = answered ? LINGER : @read_timeout
          next unless limit

          left = limit - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - (answered || heard))
          throw :left if answered && !left.positive?
          unless left.positive?
            raise Timeout::Error, "no message from the server in #{@read_timeout} seconds"
          end

          @connection.read_timeout = left
        end
        sse.finish(&block)
      ensure
        @connection.read_timeout = @read_timeout
      end

      def bodiless(verb, path, headers)
        request = verb.new(URI("#{@origin}#{path}"))
        headers.each { |key, value| request[key] = value }
        request["Accept-Encoding"] = "identity"
        request
      end
    end
  end
end
