# frozen_string_literal: true

require_relative "test_helper"

# The aborted-turn cluster: shapes an aborted stream can produce that the API
# would 400 on if replayed. The serializer must make every one wire-legal.
class TestAnthropicReplay < Minitest::Test
  SERIALIZER = Mistri::Providers::Anthropic::Serializer

  def test_signatureless_thinking_degrades_to_text_and_empty_drops
    with_signature = Mistri::Content::Thinking.new(thinking: "kept", signature: "sig")
    no_signature = Mistri::Content::Thinking.new(thinking: "was mid-thought")
    empty = Mistri::Content::Thinking.new(thinking: "")
    msg = Mistri::Message.assistant(content: [with_signature, no_signature, empty],
                                    provider: :anthropic)

    blocks = SERIALIZER.message(msg)[:content]

    assert_equal 2, blocks.length
    assert_equal({ type: "thinking", thinking: "kept", signature: "sig" }, blocks[0])
    assert_equal({ type: "text", text: "was mid-thought" }, blocks[1])
  end

  def test_empty_text_blocks_are_filtered_and_empty_tool_results_get_a_placeholder
    msg = Mistri::Message.assistant(content: [Mistri::Content::Text.new(text: ""),
                                              Mistri::Content::Text.new(text: "real")])

    assert_equal [{ type: "text", text: "real" }], SERIALIZER.message(msg)[:content]

    empty_result = Mistri::Message.tool(content: "", tool_call_id: "t1")
    wire = SERIALIZER.messages([empty_result])

    assert_equal [{ type: "text", text: " " }], wire.first[:content].first[:content]
  end

  def test_an_unserializable_block_raises_a_catchable_schema_error
    assert_raises(Mistri::SchemaError) do
      SERIALIZER.block(Object.new)
    end
  end
end
