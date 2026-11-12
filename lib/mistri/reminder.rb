# frozen_string_literal: true

module Mistri
  # A periodic reminder for long agentic runs: models drift from their
  # instructions as turns accumulate, and a short reminder at the tail of
  # the context, where attention is strongest, pulls them back. It rides
  # transform_context, so it appears fresh on the wire each time it is due
  # and never persists to the session.
  #
  #   agent = Mistri.agent("claude-opus-5-5", tools: tools,
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

    # The wire form of a harness note inside a user turn.
    def self.wrap(text) = "<system-reminder>\n#{text}\n</system-reminder>"

    # The history with each system message that is stored among the results
    # of one turn moved after them, so the results of parallel calls stay
    # together in whichever form a reminder is sent.
    def self.after_results(history)
      history.chunk_while { |a, b| (a.tool? || a.system?) && (b.tool? || b.system?) }
             .flat_map { |run| run.partition(&:tool?).flatten(1) }
    end

    # The history for a provider that sends a note as text of a user turn:
    # each reminder message as a user message of wrapped text blocks.
    def self.as_user_turns(history)
      after_results(history).map do |message|
        next message unless message.reminder

        Message.user(message.content.grep(Content::Text).map { |block| wrap(block.text) })
      end
    end

    def initialize(interval:, text:, after: nil)
      @interval = [interval.to_i, 1].max
      @after = (after || @interval).to_i
      @body = Reminder.wrap(text)
    end

    def call(messages)
      turns = messages.count(&:assistant?)
      return messages unless turns >= @after && ((turns - @after) % @interval).zero?

      messages + [Message.user(@body)]
    end
  end
end
