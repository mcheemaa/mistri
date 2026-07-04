# frozen_string_literal: true

require "json"

module Mistri
  module Sinks
    # Writes events as Server-Sent Events to any IO-like object: a Rack
    # streaming body, an ActionController::Live stream, a socket. Pure
    # formatting, the outbound counterpart of the Mistri::SSE decoder.
    #
    #   response.headers["Content-Type"] = "text/event-stream"
    #   agent.run(input, &Mistri::Sinks::SSE.new(response.stream))
    class SSE
      def initialize(io)
        @io = io
      end

      def call(event)
        @io.write("event: #{event.type}\ndata: #{JSON.generate(event.to_h)}\n\n")
        @io.flush if @io.respond_to?(:flush)
      end

      def to_proc = method(:call).to_proc
    end
  end
end
