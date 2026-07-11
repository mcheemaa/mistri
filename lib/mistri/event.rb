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
  # duration is the measured tool execution time on :tool_result events; nil
  # means no duration is available, not necessarily that no side effect ran.
  # tool_error is explicit on :tool_result and does not change Event#error?,
  # which means a terminal provider-turn failure.
  class Event < Data.define(:type, :content_index, :delta, :content, :tool_call,
                            :reason, :message, :error_message, :partial, :origin,
                            :duration, :attempt, :max_attempts, :delay,
                            :agent, :session_id, :status, :tool_error)
    # The stream types come from a provider mid-turn; the loop adds
    # :tool_started when a resolved tool commits to execution, :tool_result
    # after it finishes, :approval_needed when a gated call parks for a human,
    # :compacting/:compaction around a context
    # compaction, and :retry (with attempt, max_attempts, delay) before it
    # waits out a transient failure, so one subscription sees the whole
    # exchange. :done and :error are loop-owned and terminal: only the
    # accepted attempt's terminal event reaches the subscriber.
    # :subagent_report announces a background child's terminal outcome
    # (agent, session_id, status; content carries the report), so a UI that
    # watched the spawn can settle the child's lane the moment it ends.
    TYPES = %i[
      start
      text_start text_delta text_end
      thinking_start thinking_delta thinking_end
      toolcall_start toolcall_delta toolcall_end
      done error
      tool_started tool_result approval_needed
      compacting compaction
      retry
      subagent_report
    ].freeze

    def initialize(type:, content_index: nil, delta: nil, content: nil, tool_call: nil,
                   reason: nil, message: nil, error_message: nil, partial: nil, origin: nil,
                   duration: nil, attempt: nil, max_attempts: nil, delay: nil,
                   agent: nil, session_id: nil, status: nil, tool_error: nil)
      raise ArgumentError, "unknown event type #{type.inspect}" unless TYPES.include?(type)

      if type == :tool_result
        unless [true, false].include?(tool_error)
          raise ArgumentError, "tool_result events require a boolean tool_error"
        end
      elsif !tool_error.nil?
        raise ArgumentError, "tool_error is only valid on tool_result events"
      end
      if type == :tool_result && message && message.tool_error != tool_error
        raise ArgumentError, "event tool_error must match its message"
      end

      super
    end

    def done? = type == :done

    def error? = type == :error

    def tool_error? = tool_error == true

    def terminal? = done? || error?

    # Partials are ephemeral streaming state and stay out of serialization.
    def to_h
      { type:, content_index:, delta:, content:, tool_call: tool_call&.to_h,
        reason:, message: message&.to_h, error_message:, origin:, duration:,
        attempt:, max_attempts:, delay:, agent:, session_id:, status:, tool_error: }.compact
    end
  end
end
