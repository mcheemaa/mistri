# frozen_string_literal: true

require "json"

module Mistri
  # When a session compacts, and how much of it survives. Compaction is
  # client-side and provider-agnostic: the session's own provider writes a
  # visible summary, so a host can always show the user exactly what the
  # model still remembers.
  #
  # The trigger measures real token accounting, not guesses: the last healthy
  # turn's reported usage plus a character heuristic for whatever came after
  # it.
  class Compaction
    DEFAULT_RESERVE = 16_384
    DEFAULT_KEEP_RECENT = 20_000
    IMAGE_CHARS = 4_800

    SUMMARY_PREFACE = "The earlier conversation was compacted. This summary replaces it:"

    attr_reader :reserve, :keep_recent, :window, :instructions

    # window overrides the model catalog's context window (required for
    # models the catalog does not know). instructions add a host-specific
    # focus to the summary prompt.
    def initialize(reserve: DEFAULT_RESERVE, keep_recent: DEFAULT_KEEP_RECENT,
                   window: nil, instructions: nil)
      @reserve = reserve
      @keep_recent = keep_recent
      @window = window
      @instructions = instructions
    end

    # Compact when the context has grown into the reserve headroom. An
    # unknown window never triggers.
    def needed?(tokens, window)
      window ? tokens > window - reserve : false
    end

    class << self
      # Context size for a replay: the last healthy turn's reported tokens
      # (prompt, cache, and output all sit in context next turn) plus an
      # estimate of every message after it.
      def context_tokens(messages)
        index = messages.rindex { |message| reported(message) }
        base = index ? reported(messages[index]) : 0
        messages.drop(index ? index + 1 : 0).sum(base) { |message| estimate(message) }
      end

      def estimate(message)
        (chars(message) / 4.0).ceil
      end

      private

      def reported(message)
        return nil unless message.assistant? && message.usage
        return nil if %i[aborted error].include?(message.stop_reason)

        usage = message.usage
        total = usage.input + usage.cache_read + usage.cache_write + usage.output
        total.positive? ? total : nil
      end

      def chars(message)
        message.content.sum do |block|
          case block
          when Content::Text then block.text.length
          when Content::Thinking then block.thinking.length
          when Content::Image then IMAGE_CHARS
          when ToolCall then block.name.length + JSON.generate(block.arguments).length
          else 0
          end
        end
      end
    end
  end
end
