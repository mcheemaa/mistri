# frozen_string_literal: true

module Mistri
  module Sinks
    # Wraps any sink and merges bursts of streaming deltas, so a transport
    # broadcasts at UI speed instead of token speed. Deltas buffer per
    # content block per origin and flush merged when the interval elapses or
    # any other event arrives, so ordering is preserved and a turn always
    # ends flushed. Safe to share across threads: a background worker's
    # events serialize with the parent's instead of racing the buffer.
    #
    #   sink = Mistri::Sinks::Coalesced.new(
    #     Mistri::Sinks::ActionCable.new("agent_1"), interval: 0.1,
    #   )
    class Coalesced
      DELTAS = %i[text_delta thinking_delta toolcall_delta].freeze

      def initialize(sink, interval: 0.05)
        @sink = sink
        @interval = interval
        @buffer = nil
        @flushed_at = now
        @mutex = Mutex.new
      end

      def call(event)
        @mutex.synchronize do
          if DELTAS.include?(event.type)
            merge(event)
            flush if now - @flushed_at >= @interval
          else
            flush
            @sink.call(event)
          end
        end
      end

      def to_proc = method(:call).to_proc

      private

      # Merged deltas keep the newest partial, so a consumer that renders
      # snapshots always renders the latest one. Origin is part of a block's
      # identity: two agents' lanes never fold into one event.
      def merge(event)
        same = @buffer && @buffer.type == event.type &&
               @buffer.content_index == event.content_index &&
               @buffer.origin == event.origin
        flush if @buffer && !same
        @buffer = if same
                    @buffer.with(delta: @buffer.delta.to_s + event.delta.to_s,
                                 partial: event.partial)
                  else
                    event
                  end
      end

      def flush
        pending = @buffer
        @buffer = nil
        @flushed_at = now
        @sink.call(pending) if pending
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
