# frozen_string_literal: true

require "json"

module Mistri
  DEFAULT_MAX_RECORD_BYTES = 8 * 1024 * 1024
  private_constant :DEFAULT_MAX_RECORD_BYTES

  # An incremental Server-Sent Events decoder. Feed it raw socket fragments in
  # any chunking; it buffers partial lines across fragments and yields each
  # complete "data:" record as a parsed Hash.
  #
  # The decode is deliberately tolerant of what the provider APIs actually
  # send: one single-line JSON object per "data:" record. "event:", "id:",
  # comment, and blank lines are ignored (the event name is duplicated inside
  # the data payload), OpenAI's "[DONE]" sentinel is dropped, and a record that
  # fails to parse is skipped rather than killing a live stream. Only the
  # partial line is bounded; the complete stream is not.
  class SSE
    def initialize(max_record_bytes: DEFAULT_MAX_RECORD_BYTES)
      unless max_record_bytes.is_a?(Integer) && max_record_bytes.positive?
        raise ConfigurationError, "max_record_bytes: must be a positive integer"
      end

      @max_record_bytes = max_record_bytes
      @buffer = +""
    end

    def feed(fragment, &)
      scan = fragment.encoding == Encoding::BINARY ? fragment : fragment.b
      offset = 0
      while (newline = scan.index("\n", offset))
        append(fragment, offset, newline - offset)
        line = @buffer
        @buffer = +""
        line.chomp!
        decode(line, &)
        offset = newline + 1
      end
      append(fragment, offset, scan.bytesize - offset)
      nil
    end

    # Flush a trailing record that arrived without a final newline.
    def finish(&)
      unless @buffer.empty?
        line = @buffer
        @buffer = +""
        line.chomp!
        decode(line, &)
      end
      nil
    end

    private

    def append(fragment, offset, length)
      return if length.zero?

      if @buffer.bytesize + length > @max_record_bytes
        raise ResponseTooLargeError.new(kind: :sse_line, limit: @max_record_bytes)
      end

      @buffer << fragment.byteslice(offset, length)
    end

    def decode(line)
      return unless line.delete_prefix!("data:")

      line.strip!
      return if line.empty? || line == "[DONE]"

      case ToolArguments.raw_json_resource_error(line)
      when "too_many_nodes"
        raise ResponseTooComplexError.new(kind: :sse_record_tokens,
                                          limit: ToolArguments::MAX_LEXICAL_TOKENS)
      when "too_deep"
        raise ResponseTooComplexError.new(kind: :sse_record_depth,
                                          limit: ToolArguments::MAX_DEPTH)
      when "number_too_large"
        raise ResponseTooComplexError.new(kind: :sse_numeric_token,
                                          limit: ToolArguments::MAX_NUMBER_BYTES)
      end

      decoded = JSON.parse(line)
      yield decoded if decoded.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end
  end
end
