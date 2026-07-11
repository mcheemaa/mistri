# frozen_string_literal: true

require "json"

module Mistri
  # Owns model-supplied JSON before it crosses a durable or policy boundary.
  module ToolArguments # rubocop:disable Metrics/ModuleLength -- one JSON ownership boundary
    MAX_DEPTH = 64
    MAX_NODES = 10_000
    MAX_LEXICAL_TOKENS = (MAX_NODES * 2) + 1
    MAX_BYTES = 8 * 1024 * 1024
    MAX_NUMBER_BYTES = 64 * 1024
    EMPTY_OBJECT = {}.freeze
    ERROR_CODES = %w[
      invalid_arguments invalid_encoding invalid_json invalid_key duplicate_key
      cyclic_value too_deep too_large too_many_nodes number_too_large
      non_finite_number non_json_value incomplete
    ].freeze
    RESOURCE_ERRORS = %w[too_deep too_large too_many_nodes number_too_large].freeze

    Failure = Class.new(StandardError) do
      attr_reader :code

      def initialize(code)
        @code = code
        super
      end
    end
    private_constant :Failure

    module_function

    def canonicalize(value)
      state = { nodes: 0, bytes: 0, active: {} }
      value = copy(value, state, 0)
      raise Failure, "too_large" unless serialized_size_within_limit?(value)

      [value, nil]
    rescue Failure => e
      [nil, e.code]
    end

    # Counts the generated JSON envelope without materializing it. Integer
    # digits are conservatively bounded so a hostile Bignum cannot allocate an
    # oversized decimal string before the limit is enforced.
    def serialized_size_within_limit?(value, limit: MAX_BYTES)
      return false unless limit.is_a?(Integer) && limit >= 0

      state = { limit:, remaining: limit, active: {} }
      count_json(value, state, 0)
      true
    rescue Failure
      false
    end

    # Provider assemblers parse completed argument payloads strictly. Partial
    # JSON belongs only to transient streaming snapshots, never executable calls.
    def parse_json(raw)
      return [nil, "invalid_json"] unless raw.is_a?(String)
      return [nil, "too_large"] if raw.bytesize > MAX_BYTES
      if (resource_error = raw_json_resource_error(raw))
        return [nil, resource_error]
      end

      [JSON.parse(raw, max_nesting: MAX_DEPTH + 1), nil]
    rescue JSON::NestingError
      [nil, "too_deep"]
    rescue JSON::ParserError, TypeError
      [nil, "invalid_json"]
    end

    def normalize_error(code)
      candidate = code.to_s
      ERROR_CODES.include?(candidate) ? candidate.freeze : "invalid_arguments"
    end

    def resource_error?(code) = RESOURCE_ERRORS.include?(code)

    # A lexical pass bounds parser allocation without duplicating JSON's
    # grammar. Counting keys as tokens leaves room for every valid document
    # under MAX_NODES while stopping wide hostile inputs before JSON.parse.
    # This byte-state machine must branch on JSON token starts without building a tree.
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def raw_json_resource_error(raw)
      tokens = 0
      depth = 0
      index = 0
      while index < raw.bytesize
        byte = raw.getbyte(index)
        case byte
        when 34
          tokens += 1
          return "too_many_nodes" if tokens > MAX_LEXICAL_TOKENS

          index = string_end(raw, index + 1)
        when 91, 123
          tokens += 1
          return "too_many_nodes" if tokens > MAX_LEXICAL_TOKENS

          depth += 1
          return "too_deep" if depth > MAX_DEPTH + 1

          index += 1
        when 93, 125
          depth -= 1 if depth.positive?
          index += 1
        when 45, 48..57
          tokens += 1
          return "too_many_nodes" if tokens > MAX_LEXICAL_TOKENS

          number_start = index
          index = number_end(raw, index + 1)
          return "number_too_large" if index - number_start > MAX_NUMBER_BYTES
        when 116
          tokens += 1
          return "too_many_nodes" if tokens > MAX_LEXICAL_TOKENS

          index += raw.byteslice(index, 4) == "true" ? 4 : 1
        when 102
          tokens += 1
          return "too_many_nodes" if tokens > MAX_LEXICAL_TOKENS

          index += raw.byteslice(index, 5) == "false" ? 5 : 1
        when 110
          tokens += 1
          return "too_many_nodes" if tokens > MAX_LEXICAL_TOKENS

          index += raw.byteslice(index, 4) == "null" ? 4 : 1
        else
          index += 1
        end
      end
      nil
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def string_end(raw, index)
      while index < raw.bytesize
        case raw.getbyte(index)
        when 34 then return index + 1
        when 92 then index += 2
        else index += 1
        end
      end
      index
    end
    private_class_method :string_end

    def number_end(raw, index)
      while index < raw.bytesize
        byte = raw.getbyte(index)
        break unless byte == 43 || byte == 45 || byte == 46 || byte == 69 || byte == 101 ||
                     byte.between?(48, 57)

        index += 1
      end
      index
    end
    private_class_method :number_end

    # Anthropic and Gemini require an object when an earlier invalid call is
    # replayed. The paired error result preserves the truth; this shape only
    # keeps the provider transcript structurally valid.
    def replay_object(call)
      return EMPTY_OBJECT if call.arguments_error
      return EMPTY_OBJECT unless call.arguments.is_a?(Hash)

      call.arguments
    end

    # OpenAI carries function arguments as a JSON string, so every completed
    # JSON value can replay exactly; only an unparseable value needs a placeholder.
    def replay_value(call)
      call.arguments_error ? EMPTY_OBJECT : call.arguments
    end

    # Assemblers own freshly parsed previews, so they can freeze the tree in
    # place without the copy that completed values require.
    def freeze_partial(value)
      return value if value.frozen?

      case value
      when Hash
        value.each do |key, nested|
          freeze_partial(key)
          freeze_partial(nested)
        end
      when Array
        value.each { |nested| freeze_partial(nested) }
      end
      value.freeze if value.respond_to?(:freeze)
      value
    end

    def copy(value, state, depth)
      raise Failure, "too_deep" if depth > MAX_DEPTH

      state[:nodes] += 1
      raise Failure, "too_large" if state[:nodes] > MAX_NODES

      case value
      when nil, true, false then value
      when Integer then copy_integer(value)
      when Float then copy_float(value)
      when String then copy_string(value, state)
      when Array then copy_array(value, state, depth)
      when Hash then copy_hash(value, state, depth)
      else raise Failure, "non_json_value"
      end
    end
    private_class_method :copy

    def copy_float(value)
      raise Failure, "non_finite_number" unless value.finite?

      value
    end
    private_class_method :copy_float

    def copy_integer(value)
      upper_bound = integer_decimal_upper_bound(value)
      raise Failure, "number_too_large" if upper_bound > MAX_NUMBER_BYTES + 1
      if upper_bound > MAX_NUMBER_BYTES && value.to_s.bytesize > MAX_NUMBER_BYTES
        raise Failure, "number_too_large"
      end

      value
    end
    private_class_method :copy_integer

    def copy_string(value, state)
      string = if value.encoding == Encoding::UTF_8
                 raise Failure, "too_large" if value.bytesize > MAX_BYTES - state[:bytes]
                 raise Failure, "invalid_encoding" unless value.valid_encoding?

                 value.dup
               else
                 value.encode(Encoding::UTF_8)
               end
      state[:bytes] += string.bytesize
      raise Failure, "too_large" if state[:bytes] > MAX_BYTES

      string.freeze
    rescue EncodingError
      raise Failure, "invalid_encoding"
    end
    private_class_method :copy_string

    def copy_array(value, state, depth)
      within(value, state) do
        copied = []
        # Array#map preallocates from an untrusted length before the node ceiling fires.
        # rubocop:disable Style/MapIntoArray
        value.each { |item| copied << copy(item, state, depth + 1) }
        # rubocop:enable Style/MapIntoArray
        copied.freeze
      end
    end
    private_class_method :copy_array

    def copy_hash(value, state, depth)
      within(value, state) do
        value.each_with_object({}) do |(key, item), copy|
          key = copy_key(key, state)
          raise Failure, "duplicate_key" if copy.key?(key)

          copy[key] = copy(item, state, depth + 1)
        end.freeze
      end
    end
    private_class_method :copy_hash

    def copy_key(key, state)
      raise Failure, "invalid_key" unless key.is_a?(String) || key.is_a?(Symbol)

      copy_string(key.to_s, state)
    end
    private_class_method :copy_key

    def within(value, state)
      identity = value.object_id
      raise Failure, "cyclic_value" if state[:active].key?(identity)

      state[:active][identity] = true
      inserted = true
      yield
    ensure
      state[:active].delete(identity) if inserted
    end
    private_class_method :within

    def count_json(value, state, depth)
      raise Failure, "too_deep" if depth > MAX_DEPTH

      case value
      when nil, true then consume(state, 4)
      when false then consume(state, 5)
      when Integer then count_integer(value, state)
      when Float then count_float(value, state)
      when String then count_string(value, state)
      when Array then count_array(value, state, depth)
      when Hash then count_hash(value, state, depth)
      else raise Failure, "non_json_value"
      end
    end
    private_class_method :count_json

    def count_float(value, state)
      raise Failure, "non_finite_number" unless value.finite?

      consume(state, JSON.generate(value).bytesize)
    end
    private_class_method :count_float

    def count_integer(value, state)
      copy_integer(value)
      upper_bound = integer_decimal_upper_bound(value)
      # A bit length can straddle one decimal boundary. One byte of bounded
      # slack lets the exact count decide without exposing an oversized allocation.
      raise Failure, "too_large" if upper_bound > state[:limit] + 1

      consume(state, value.to_s.bytesize)
    end
    private_class_method :count_integer

    def integer_decimal_upper_bound(value)
      digits = ((value.bit_length * 30_103) / 100_000) + 1
      digits + (value.negative? ? 1 : 0)
    end
    private_class_method :integer_decimal_upper_bound

    def count_string(value, state)
      valid_utf8 = value.encoding == Encoding::UTF_8 && value.valid_encoding?
      raise Failure, "invalid_encoding" unless valid_utf8

      short_controls = value.count("\b\t\n\f\r")
      controls = value.count("\u0000-\u001f")
      escaped = value.count('"') + value.count("\\")
      size = value.bytesize + 2 + escaped + short_controls + ((controls - short_controls) * 5)
      consume(state, size)
    end
    private_class_method :count_string

    def count_array(value, state, depth)
      within(value, state) do
        consume(state, 2)
        value.each_with_index do |item, index|
          consume(state, 1) unless index.zero?
          count_json(item, state, depth + 1)
        end
      end
    end
    private_class_method :count_array

    def count_hash(value, state, depth)
      within(value, state) do
        consume(state, 2)
        value.each_with_index do |(key, item), index|
          raise Failure, "invalid_key" unless key.is_a?(String)

          consume(state, 1) unless index.zero?
          count_string(key, state)
          consume(state, 1)
          count_json(item, state, depth + 1)
        end
      end
    end
    private_class_method :count_hash

    def consume(state, bytes)
      raise Failure, "too_large" if bytes > state[:remaining]

      state[:remaining] -= bytes
    end
    private_class_method :consume
  end # rubocop:enable Metrics/ModuleLength
end
