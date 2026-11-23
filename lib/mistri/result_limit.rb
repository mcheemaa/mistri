# frozen_string_literal: true

module Mistri
  # How much of a tool result is stored, and so sent to the model with every
  # later request. The results that answer one assistant message share
  # turn_bytes, because a compaction never makes one turn smaller.
  class ResultLimit
    DEFAULT_BYTES = 50_000
    DEFAULT_TURN_BYTES = 200_000
    SHARED_FLOOR_BYTES = 2_000
    SHOWN_BYTES = 2_000

    OWN = "[This result was %<bytes>d bytes in %<lines>d lines. Only its start is above. The " \
          "rest was not kept. If the tool can page or filter its results, call it again for " \
          "the part you need.]"
    SHARED = "[This result was %<bytes>d bytes in %<lines>d lines. Only its start is above, " \
             "because the results of tool calls made together share one limit. The rest was " \
             "not kept. If the tool can page or filter its results, call it again for the " \
             "part you need, with fewer calls at a time.]"
    UNSAVED = "[This result was %<bytes>d bytes in %<lines>d lines. Only its start is above. " \
              "It could not be saved, so the rest was not kept. If the tool can page or " \
              "filter its results, call it again for the part you need.]"
    SAVED = "[This result is %<bytes>d bytes in %<lines>d lines. Only its start is above. The " \
            "whole is saved at %<path>s. Read it in parts with read_file, or search it with " \
            "grep.]"
    private_constant :OWN, :SHARED, :UNSAVED, :SAVED

    # The limit of each result of one assistant message, asked for as the
    # results are stored. left is tracked as well, because a hook can make a
    # result larger than the tool returned it.
    class Turn
      def initialize(level, left)
        @level = level
        @left = left
      end

      def limit(own_limit)
        left = [@left, SHARED_FLOOR_BYTES].max
        [own_limit, @level || own_limit, left].min
      end

      def spend(bytes)
        @left -= bytes
      end
    end
    private_constant :Turn

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

    # What each of the results of one turn can keep whatever the others hold.
    # The level of a turn is never under it.
    def share(count, spent: 0)
      [[turn_bytes - spent, 0].max / count, SHARED_FLOOR_BYTES].max
    end

    def turn(sizes, spent: 0)
      left = turn_bytes - spent
      Turn.new(sizes.sum <= left ? nil : level(sizes, [left, 0].max), left)
    end

    def bound(content, limit = bytes, shared: false, unsaved: false)
      texts = self.class.texts(content)
      size = texts.sum(&:bytesize)
      return [content, nil] if size <= limit

      cut = { "bytes" => size, "lines" => texts.sum { |text| lines(text) } }
      wording = if unsaved
                  UNSAVED
                else
                  shared ? SHARED : OWN
                end
      notice = format(wording, bytes: size, lines: cut["lines"])
      [cut_to(content, [limit - notice.bytesize - 1, 0].max, notice), cut]
    end

    def shown(text, path)
      cut = { "bytes" => text.bytesize, "lines" => lines(text), "path" => path }
      ["#{start_of(text, SHOWN_BYTES)}\n#{format(SAVED, **cut.transform_keys(&:to_sym))}", cut]
    end

    private

    # The largest results give way first, down to one level for all of them,
    # so a small result stays whole beside a large one.
    def level(sizes, left)
      remaining = sizes.length
      sizes.sort.each do |size|
        break if size * remaining > left

        left -= size
        remaining -= 1
      end
      [left / remaining, SHARED_FLOOR_BYTES].max
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

    # A cut at a line end, unless that loses more than half of what fits.
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
