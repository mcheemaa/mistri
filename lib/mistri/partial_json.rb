# frozen_string_literal: true

require "json"

module Mistri
  # Parses the JSON prefix a model has emitted so far, so in-flight tool-call
  # arguments are readable before the closing brace arrives. Best effort by
  # contract: never raises, drops a dangling key or half-written token, and
  # returns {} for hopeless input.
  module PartialJson
    def self.parse(text)
      s = text.to_s.strip
      return {} if s.empty?

      value = Parser.new(s).parse
      value.equal?(Parser::NOTHING) ? {} : value
    rescue StandardError
      {}
    end

    # Recursive descent over the prefix. Truncation trips @partial, and every
    # frame unwinds keeping the structure built so far.
    class Parser
      NOTHING = Object.new
      LITERALS = { "true" => true, "false" => false, "null" => nil }.freeze

      def initialize(source)
        @s = source
        @n = source.length
        @i = 0
        @partial = false
      end

      def parse = value

      private

      def value
        skip_ws
        return truncated if eof?

        case @s[@i]
        when '"' then string
        when "{" then object
        when "[" then array
        else scalar
        end
      end

      def object
        @i += 1
        obj = {}
        until @partial
          skip_ws
          break truncated if eof?
          break @i += 1 if @s[@i] == "}"
          break unless @s[@i] == '"'

          key, val = pair
          obj[key] = val unless key.equal?(NOTHING) || val.equal?(NOTHING)
          skip_ws
          @i += 1 if !eof? && @s[@i] == ","
        end
        obj
      end

      # One key/value. A truncation before the value completes the key's
      # last-known state: mid-key or mid-separator drops the pair entirely.
      def pair
        key = string
        return [NOTHING, NOTHING] if @partial

        skip_ws
        return [NOTHING, truncated] if eof?
        return [NOTHING, NOTHING] unless @s[@i] == ":"

        @i += 1
        [key, value]
      end

      def array
        @i += 1
        arr = []
        until @partial
          skip_ws
          break truncated if eof?
          break @i += 1 if @s[@i] == "]"

          element = value
          arr << element unless element.equal?(NOTHING)
          skip_ws
          @i += 1 if !eof? && @s[@i] == ","
        end
        arr
      end

      def string
        start = @i
        @i += 1
        escaped = false
        while @i < @n
          case
          when escaped then escaped = false
          when @s[@i] == "\\" then escaped = true
          when @s[@i] == '"'
            @i += 1
            return decode(@s[start...@i])
          end
          @i += 1
        end
        truncated
        salvage_string(@s[start..])
      end

      # Close an unterminated string, first shedding a half-written escape
      # (a lone backslash or a partial \uXXXX).
      def salvage_string(fragment)
        candidate = fragment.sub(/\\u[0-9a-fA-F]{0,3}\z/, "").sub(/\\\z/, "")
        decode(%(#{candidate}"))
      end

      def scalar
        start = @i
        @i += 1 while @i < @n && !"},] \n\r\t".include?(@s[@i])
        token = @s[start...@i]
        # A structural character in value position: consume it so the caller's
        # loop always makes progress.
        return (@i += 1) && NOTHING if token.empty?

        truncated if eof?
        literal(token) { number(token) }
      end

      def literal(token)
        return LITERALS[token] if LITERALS.key?(token)

        if @partial
          match = LITERALS.keys.find { |word| word.start_with?(token) }
          return LITERALS[match] if match
        end
        yield
      end

      def number(token)
        Integer(token)
      rescue ArgumentError
        begin
          Float(token)
        rescue ArgumentError
          trimmed_number(token)
        end
      end

      # A number cut mid-token: shed the dangling exponent, decimal point, or
      # bare minus and retry.
      def trimmed_number(token)
        trimmed = token.sub(/[eE][+-]?\z/, "").sub(/\.\z/, "")
        return NOTHING if trimmed.empty? || trimmed == "-"

        Float(trimmed)
      rescue ArgumentError
        NOTHING
      end

      def decode(json_string)
        JSON.parse(json_string)
      rescue JSON::ParserError
        NOTHING
      end

      def skip_ws
        @i += 1 while @i < @n && " \n\r\t".include?(@s[@i])
      end

      def eof? = @i >= @n

      def truncated
        @partial = true
        NOTHING
      end
    end
  end
end
