# frozen_string_literal: true

module Mistri
  # How much of a tool result is stored, and so sent to the model with every
  # later request. One result keeps its start up to bytes. The results that
  # answer one assistant message share turn_bytes: a compaction never makes
  # one turn smaller, so a turn has to fit by itself.
  #
  #   Mistri.agent("claude-opus-5-5", result_limit: Mistri::ResultLimit.new(bytes: 20_000))
  #
  # result_limit: false stores every result whole.
  class ResultLimit
    DEFAULT_BYTES = 50_000
    DEFAULT_TURN_BYTES = 200_000
    # What each result of a crowded turn keeps at least.
    FLOOR_BYTES = 2_000

    OWN = "[This result was %<bytes>d bytes in %<lines>d lines. Only its start is above. The " \
          "rest was not kept. If the tool can page or filter its results, call it again for " \
          "the part you need.]"
    SHARED = "[This result was %<bytes>d bytes in %<lines>d lines. Only its start is above, " \
             "because the results of tool calls made together share one limit. The rest was " \
             "not kept. If the tool can page or filter its results, call it again for the " \
             "part you need, with fewer calls at a time.]"
    private_constant :OWN, :SHARED

    # The limit of each result of one assistant message, asked for as the
    # results are stored one after another. left holds the turn to its bytes
    # when a hook made a result larger than the tool returned it.
    class Turn
      def initialize(level, left)
        @level = level
        @left = left
      end

      def limit
        left = [@left, FLOOR_BYTES].max
        [left, @level].min
      end

      def spend(bytes)
        @left -= bytes
      end
    end

    attr_reader :bytes, :turn_bytes

    def self.texts(content)
      Array(content).filter_map do |block|
        case block
        when String then block
        when Content::Text then block.text
        end
      end
    end

    def self.size(content) = texts(content).sum(&:bytesize)

    def initialize(bytes: DEFAULT_BYTES, turn_bytes: DEFAULT_TURN_BYTES)
      unless [bytes, turn_bytes].all? { |value| value.is_a?(Integer) && value.positive? }
        raise ArgumentError, "bytes and turn_bytes must be positive Integers"
      end

      @bytes = bytes
      @turn_bytes = turn_bytes
    end

    # sizes are the results of one assistant message as the tools returned
    # them. Over the turn's bytes, the largest give way first, down to one
    # level for all of them, so a small result stays whole beside a large
    # one. spent is what the message's earlier results already hold.
    def turn(sizes, spent: 0)
      capped = sizes.map { |size| [size, bytes].min }
      left = turn_bytes - spent
      Turn.new(capped.sum <= left ? bytes : level(capped, [left, 0].max), left)
    end

    # The content with its text cut to limit bytes, and what was cut: the
    # true bytes and lines, or nil for content that fits. Images stay.
    def bound(content, limit = bytes)
      texts = self.class.texts(content)
      size = texts.sum(&:bytesize)
      return [content, nil] if size <= limit

      cut = { "bytes" => size, "lines" => texts.sum { |text| lines(text) } }
      notice = format(limit < bytes ? SHARED : OWN, bytes: size, lines: cut["lines"])
      [cut_to(content, [limit - notice.bytesize - 1, 0].max, notice), cut]
    end

    private

    def level(sizes, left)
      remaining = sizes.length
      sizes.sort.each do |size|
        break if size * remaining > left

        left -= size
        remaining -= 1
      end
      [left / remaining, FLOOR_BYTES].max
    end

    def cut_to(content, limit, notice)
      return "#{start_of(content, limit)}\n#{notice}" if content.is_a?(String)

      blocks = Array(content).filter_map do |block|
        text = self.class.texts(block).first
        next block unless text
        next if limit <= 0

        start = start_of(text, limit)
        limit -= text.bytesize
        Content::Text.new(text: start)
      end
      blocks << Content::Text.new(text: notice)
    end

    # Whole lines where the text has them, and never half a character.
    def start_of(text, limit)
      return text if text.bytesize <= limit

      start = text.byteslice(0, limit).scrub("")
      line_end = start.rindex("\n")
      line_end && line_end >= start.length / 2 ? start[0...line_end] : start
    end

    def lines(text)
      text.count("\n") + (text.end_with?("\n") ? 0 : 1)
    end
  end
end
