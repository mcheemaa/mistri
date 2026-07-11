# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestContent < Minitest::Test
  def test_blocks_round_trip_through_json
    blocks = [
      Mistri::Content::Text.new(text: "hello"),
      Mistri::Content::Thinking.new(thinking: "hmm", signature: "sig", redacted: true),
      Mistri::Content::Image.from_bytes("\x89PNG".b, mime_type: "image/png"),
      Mistri::ToolCall.new(id: "call_1", name: "search", arguments: { "q" => "ruby" })
    ]

    restored = blocks.map { |b| Mistri::Content.from_h(JSON.parse(JSON.generate(b.to_h))) }

    assert_equal blocks, restored
  end

  def test_image_decodes_back_to_its_bytes
    image = Mistri::Content::Image.from_bytes("raw bytes", mime_type: "image/jpeg")

    assert_equal "raw bytes", image.bytes
  end

  def test_blocks_own_frozen_copies_of_their_strings
    buffer = +"ZGF0YQ=="
    image = Mistri::Content::Image.new(data: buffer, mime_type: "image/png")
    buffer << "XX"

    assert_equal "ZGF0YQ==", image.data
    assert_predicate image.data, :frozen?
  end

  def test_replay_signatures_are_owned_by_their_content_blocks
    text_signature = +"message-id"
    thinking_signature = +"opaque-state"
    text = Mistri::Content::Text.new(text: "done", signature: text_signature)
    thinking = Mistri::Content::Thinking.new(thinking: "why", signature: thinking_signature)

    text_signature << " changed"
    thinking_signature << " changed"

    assert_equal "message-id", text.signature
    assert_equal "opaque-state", thinking.signature
    assert_predicate text.signature, :frozen?
    assert_predicate thinking.signature, :frozen?
  end

  def test_tool_call_owns_its_arguments
    query = +"ruby"
    nested = [{ "q" => query }]
    args = { config: nested }
    call = Mistri::ToolCall.new(id: "c1", name: "search", arguments: args)
    query << " changed"
    nested << { "q" => "other" }
    args[:config] = []

    assert_equal({ "config" => [{ "q" => "ruby" }] }, call.arguments)
    assert_predicate call.arguments, :frozen?
    assert_predicate call.arguments["config"], :frozen?
    assert_predicate call.arguments.dig("config", 0, "q"), :frozen?
    assert_raises(FrozenError) { call.arguments["config"] << "nope" }
  end

  def test_tool_call_owns_its_pairing_strings
    id = +"c1"
    name = +"search"
    signature = +"provider-state"
    provider_call_id = +"provider-call"
    call = Mistri::ToolCall.new(id:, name:, signature:, provider_call_id:, arguments: {})

    id << " changed"
    name << " changed"
    signature << " changed"
    provider_call_id << " changed"

    assert_equal %w[c1 search provider-state provider-call],
                 [call.id, call.name, call.signature, call.provider_call_id]
    assert_predicate call.id, :frozen?
    assert_predicate call.name, :frozen?
    assert_predicate call.signature, :frozen?
    assert_predicate call.provider_call_id, :frozen?
  end

  def test_partial_argument_previews_are_deeply_frozen_only_once
    counting_hash = Class.new(Hash) do
      attr_reader :walks

      def each(...)
        @walks = (@walks || 0) + 1
        super
      end
    end
    nested = counting_hash.new
    nested["items"] = [{ "value" => "partial" }]

    arguments = Mistri.const_get(:ToolArguments, false)
    first = arguments.freeze_partial(nested)
    walks = nested.walks
    second = arguments.freeze_partial(nested)

    assert_predicate first, :frozen?
    assert_predicate first["items"], :frozen?
    assert_predicate first.dig("items", 0), :frozen?
    assert_equal walks, nested.walks, "a cached frozen preview is O(1) to reuse"
    assert_same first, second
  end

  def test_tool_call_preserves_every_json_top_level_and_explicit_null
    [nil, false, 7, 2.5, "text", [1, { "x" => true }], { "x" => 1 }].each do |value|
      call = Mistri::ToolCall.new(id: "c1", name: "inspect", arguments: value)
      restored = Mistri::Content.from_h(JSON.parse(JSON.generate(call.to_h)))

      value.nil? ? assert_nil(call.arguments) : assert_equal(value, call.arguments)

      assert_equal call, restored
      assert call.to_h.key?(:arguments), "arguments must survive even when null"
    end

    legacy = Mistri::Content.from_h(type: "tool_call", id: "old", name: "inspect")

    assert_equal({}, legacy.arguments, "entries written before arguments existed stay compatible")
  end

  def test_tool_call_rejects_values_that_are_not_bounded_json
    cycle = []
    cycle << cycle
    invalid_utf8 = "\xFF".b
    too_deep = nil
    65.times { too_deep = [too_deep] }
    too_large = Array.new(10_000)
    cases = [[{ a: 1, "a" => 2 }, "duplicate_key"],
             [{ 1 => "value" }, "invalid_key"],
             [cycle, "cyclic_value"],
             [Object.new, "non_json_value"],
             [Float::INFINITY, "non_finite_number"],
             [invalid_utf8, "invalid_encoding"],
             [too_deep, "too_deep"],
             [too_large, "too_large"]]

    cases.each do |value, code|
      call = Mistri::ToolCall.new(id: "c1", name: "inspect", arguments: value)

      assert_nil call.arguments
      assert_equal code, call.arguments_error
      assert_equal({ type: :tool_call, id: "c1", name: "inspect", arguments: nil,
                     arguments_error: code }, call.to_h)
    end
  end

  def test_oversized_arrays_are_copied_incrementally
    hostile = Class.new(Array) do
      def map(*) = raise("canonicalization preallocated from the hostile length")
    end.new(10_001)

    call = Mistri::ToolCall.new(id: "large", name: "inspect", arguments: hostile)

    assert_nil call.arguments
    assert_equal "too_large", call.arguments_error
  end

  def test_oversized_strings_are_rejected_before_they_are_copied
    arguments = Mistri.const_get(:ToolArguments, false)
    hostile = Class.new(String) do
      def dup = raise("canonicalization copied a string beyond the byte limit")
    end.new("x" * (arguments::MAX_BYTES + 1))

    call = Mistri::ToolCall.new(id: "large", name: "inspect", arguments: hostile)

    assert_nil call.arguments
    assert_equal "too_large", call.arguments_error
  end

  def test_completed_argument_ceiling_counts_the_json_wire_shape
    arguments = Mistri.const_get(:ToolArguments, false)
    limit = arguments::MAX_BYTES
    escaped = "\u0000" * ((limit / 6) + 1)
    huge_integer = 1 << 28_000_000

    escaped_call = Mistri::ToolCall.new(id: "escaped", name: "inspect",
                                        arguments: { "value" => escaped })
    integer_call = Mistri::ToolCall.new(id: "integer", name: "inspect",
                                        arguments: { "value" => huge_integer })

    assert_nil escaped_call.arguments
    assert_equal "too_large", escaped_call.arguments_error
    assert_nil integer_call.arguments
    assert_equal "number_too_large", integer_call.arguments_error

    value = { "x" => "\u0000" }

    assert arguments.serialized_size_within_limit?(value, limit: 14)
    refute arguments.serialized_size_within_limit?(value, limit: 13)

    exact_values = [nil, true, false, -123_456_789, 1.25,
                    "\u0000\b\t\n\f\r\\\"é", [1, "x"], { "a" => [false] }]
    exact_values.each do |candidate|
      bytes = JSON.generate(candidate).bytesize

      assert arguments.serialized_size_within_limit?(candidate, limit: bytes)
      refute arguments.serialized_size_within_limit?(candidate, limit: bytes - 1)
    end
  end

  def test_programmatic_integer_tokens_obey_the_encoded_input_limit
    arguments = Mistri.const_get(:ToolArguments, false)
    huge_integer = 1 << ((arguments::MAX_NUMBER_BYTES + 1) * 4)

    call = Mistri::ToolCall.new(id: "large", name: "inspect",
                                arguments: { "value" => huge_integer })

    assert_nil call.arguments
    assert_equal "number_too_large", call.arguments_error
  end

  def test_encoded_json_width_is_bounded_before_parser_allocation
    arguments = Mistri.const_get(:ToolArguments, false)
    wide_array = "[#{Array.new(20_002, "0").join(",")}]"
    wide_object = "{#{Array.new(10_001) { |index| "\"k#{index}\":0" }.join(",")}}"
    parse_called = false
    trace = TracePoint.new(:call) do |event|
      json_parse = event.defined_class == JSON.singleton_class && event.method_id == :parse
      parse_called = true if json_parse
    end

    errors = trace.enable do
      [arguments.parse_json(wide_array).last, arguments.parse_json(wide_object).last]
    end

    assert_equal %w[too_many_nodes too_many_nodes], errors
    refute parse_called

    huge_number = "1" * (arguments::MAX_NUMBER_BYTES + 1)
    parse_called = false
    numeric_error = trace.enable { arguments.parse_json(huge_number).last }

    assert_equal "number_too_large", numeric_error
    refute parse_called

    punctuation = JSON.generate(
      "text" => "escaped \" quote, colon: braces {} and brackets []",
      "values" => [1, 2]
    )
    parsed, error = arguments.parse_json(punctuation)

    assert_nil error
    assert_equal [1, 2], parsed["values"]
  end

  def test_tool_call_allows_shared_acyclic_values_and_exact_bounds
    shared = ["value"]
    at_depth = nil
    64.times { at_depth = [at_depth] }
    at_size = Array.new(9_999)

    call = Mistri::ToolCall.new(id: "c1", name: "inspect",
                                arguments: { "left" => shared, "right" => shared })

    assert_nil call.arguments_error
    assert_equal ["value"], call.arguments["left"]
    refute_same call.arguments["left"], call.arguments["right"]
    assert_nil Mistri::ToolCall.new(id: "depth", name: "inspect",
                                    arguments: at_depth).arguments_error
    assert_nil Mistri::ToolCall.new(id: "size", name: "inspect",
                                    arguments: at_size).arguments_error
  end

  def test_persisted_argument_errors_are_closed_and_safe
    call = Mistri::Content.from_h(type: "tool_call", id: "c1", name: "inspect",
                                  arguments: { "secret" => "do not preserve" },
                                  arguments_error: "future_internal_detail")

    assert_nil call.arguments
    assert_equal "invalid_arguments", call.arguments_error
  end

  def test_tool_call_with_reenters_the_argument_ownership_boundary
    original = Mistri::ToolCall.new(id: "c1", name: "inspect", arguments: {})
    nested = [{ key: +"value" }]

    replaced = original.with(arguments: { payload: nested })
    nested.first[:key] << " changed"

    assert_equal({ "payload" => [{ "key" => "value" }] }, replaced.arguments)
    assert_predicate replaced.arguments.dig("payload", 0), :frozen?
  end

  def test_wrap_coerces_strings_and_passes_blocks_through
    image = Mistri::Content::Image.new(data: "e30=", mime_type: "image/png")
    blocks = Mistri::Content.wrap(["look at this", image])

    assert_equal [Mistri::Content::Text.new(text: "look at this"), image], blocks
    assert_empty Mistri::Content.wrap(nil)
  end

  def test_blocks_pattern_match
    result = case Mistri::Content.from_h({ type: :thinking, thinking: "why", redacted: true })
             in Mistri::Content::Thinking(thinking:, redacted: true) then thinking
             end

    assert_equal "why", result
  end

  def test_unknown_block_type_raises
    assert_raises(ArgumentError) { Mistri::Content.from_h({ type: "video" }) }
  end

  def test_an_image_parses_from_a_data_uri
    png = "fakepngbytes"
    uri = "data:image/png;base64,#{[png].pack("m0")}"
    image = Mistri::Content::Image.from_data_uri(uri)

    assert_equal "image/png", image.mime_type
    assert_equal png, image.bytes

    assert_raises(ArgumentError) { Mistri::Content::Image.from_data_uri("https://x/y.png") }
  end
end
