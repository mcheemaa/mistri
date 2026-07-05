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

  def test_tool_call_owns_its_arguments
    args = { "q" => "ruby" }
    call = Mistri::ToolCall.new(id: "c1", name: "search", arguments: args)
    args["q"] = "changed"

    assert_equal "ruby", call.arguments["q"]
    assert_raises(FrozenError) { call.arguments["q"] = "nope" }
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
