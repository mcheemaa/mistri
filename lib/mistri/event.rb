# frozen_string_literal: true

module Mistri
  # One event in a streamed assistant turn. A stream is one :start, then a
  # start/delta/end trio per content block (text, thinking, or toolcall), then
  # exactly one terminal event: :done on success or :error on failure, carrying
  # the complete message and its stop reason.
  #
  # `partial` is an immutable snapshot of the assistant message so far, safe to
  # hold across events. `content_index` is the block's position in that
  # message's content list.
  # origin names the sub-agent an event came from: nil for this agent's own
  # turns, and nesting joins names left to right ("researcher>writer").
  # duration is the tool's execution time in seconds on :tool_result
  # events; nil where nothing ran (denials, interruptions).
  class Event < Data.define(:type, :content_index, :delta, :content, :tool_call,
                            :reason, :message, :error_message, :partial, :origin,
                            :duration, :attempt, :max_attempts, :delay)
    # The stream types come from a provider mid-turn; the loop adds
    # :tool_result after it runs each tool, :approval_needed when a gated
    # call parks for a human, :compacting/:compaction around a context
    # compaction, and :retry (with attempt, max_attempts, delay) before it
    # waits out a transient failure, so one subscription sees the whole
    # exchange. :done and :error are loop-owned and terminal: only the
    # accepted attempt's terminal event reaches the subscriber.
    TYPES = %i[
      start
      text_start text_delta text_end
      thinking_start thinking_delta thinking_end
      toolcall_start toolcall_delta toolcall_end
      done error
      tool_result approval_needed
      compacting compaction
      retry
    ].freeze

    def initialize(type:, content_index: nil, delta: nil, content: nil, tool_call: nil,
                   reason: nil, message: nil, error_message: nil, partial: nil, origin: nil,
                   duration: nil, attempt: nil, max_attempts: nil, delay: nil)
      raise ArgumentError, "unknown event type #{type.inspect}" unless TYPES.include?(type)

      super
    end

    def done? = type == :done

    def error? = type == :error

    def terminal? = done? || error?

    # Partials are ephemeral streaming state and stay out of serialization.
    def to_h
      { type:, content_index:, delta:, content:, tool_call: tool_call&.to_h,
        reason:, message: message&.to_h, error_message:, origin:, duration:,
        attempt:, max_attempts:, delay: }.compact
    end
  end
end
