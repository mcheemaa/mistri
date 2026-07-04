# frozen_string_literal: true

module Mistri
  module Sinks
    # Broadcasts every event to an Action Cable stream as its to_h shape.
    # The server resolves lazily at first call, so this file loads without
    # Rails; pass server: explicitly to use another broadcaster.
    #
    #   sink = Mistri::Sinks::ActionCable.new("agent_#{session.id}")
    #   agent.run(input, &sink)
    class ActionCable
      def initialize(stream, server: nil)
        @stream = stream
        @server = server
      end

      def call(event)
        server.broadcast(@stream, event.to_h)
      end

      def to_proc = method(:call).to_proc

      private

      def server
        @server ||= ::ActionCable.server
      end
    end
  end
end
