# frozen_string_literal: true

require "json"

module Mistri
  # An incremental Server-Sent Events decoder. Feed it raw socket fragments in
  # any chunking; it buffers partial lines across fragments and yields each
  # complete "data:" record as a parsed Hash.
  #
  # The decode is deliberately tolerant of what the provider APIs actually
  # send: one single-line JSON object per "data:" record. "event:", "id:",
  # comment, and blank lines are ignored (the event name is duplicated inside
  # the data payload), OpenAI's "[DONE]" sentinel is dropped, and a record that
  # fails to parse is skipped rather than killing a live stream.
  class SSE
    def initialize
      @buffer = +""
    end

    def feed(fragment, &)
      @buffer << fragment
      while (newline = @buffer.index("\n"))
        line = @buffer.slice!(0, newline + 1)
        decode(line.chomp, &)
      end
      nil
    end

    # Flush a trailing record that arrived without a final newline.
    def finish(&)
      decode(@buffer.chomp, &) unless @buffer.empty?
      @buffer.clear
      nil
    end

    private

    def decode(line)
      return unless line.start_with?("data:")

      data = line.delete_prefix("data:").strip
      return if data.empty? || data == "[DONE]"

      decoded = JSON.parse(data)
      yield decoded if decoded.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end
  end
end
