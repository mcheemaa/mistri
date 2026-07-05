# frozen_string_literal: true

module Mistri
  # A periodic reminder for long agentic runs: models drift from their
  # instructions as turns accumulate, and a short reminder at the tail of
  # the context, where attention is strongest, pulls them back. It rides
  # transform_context, so it appears fresh on the wire each time it is due
  # and never persists to the session.
  #
  #   agent = Mistri.agent("claude-opus-4-8", tools: tools,
  #                        transform_context: Mistri::Reminder.every(
  #                          3, "Stay on gifting. Verify with tools before claiming.",
  #                        ))
  #
  # Due is counted in completed assistant turns: the first reminder lands
  # once `after` turns have finished (default: one full interval), then
  # every `interval` turns.
  class Reminder
    def self.every(interval, text, after: nil)
      new(interval: interval, text: text, after: after)
    end

    def initialize(interval:, text:, after: nil)
      @interval = [interval.to_i, 1].max
      @after = (after || @interval).to_i
      @body = "<system-reminder>\n#{text}\n</system-reminder>"
    end

    def call(messages)
      turns = messages.count(&:assistant?)
      return messages unless turns >= @after && ((turns - @after) % @interval).zero?

      messages + [Message.user(@body)]
    end
  end
end
