# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestOpenAISerializer < Minitest::Test
  SERIALIZER = Mistri::Providers::OpenAI::Serializer

  def test_a_freeform_object_schema_passes_through
    tool = Mistri::Tool.define("render", "d", schema: lambda {
      object :config, "Open configuration", required: true
    }) { "ok" }

    wire = SERIALIZER.tools([tool.spec])

    assert_equal tool.input_schema, wire.first[:parameters]
  end

  def test_an_assembled_turn_replays_with_its_pairing_intact
    reasoning_item = { "type" => "reasoning", "id" => "rs_1", "summary" => [],
                       "encrypted_content" => "opaque" }
    assistant = Mistri::Message.assistant(
      content: [
        Mistri::Content::Thinking.new(thinking: "", signature: JSON.generate(reasoning_item)),
        Mistri::Content::Text.new(text: "Looking.", signature: "msg_1")
      ],
      tool_calls: [Mistri::ToolCall.new(id: "call_1", name: "search",
                                        arguments: { "q" => "ruby" }, signature: "fc_1")],
      stop_reason: :tool_use
    )
    history = [Mistri::Message.user("go"), assistant,
               Mistri::Message.tool(content: "found it", tool_call_id: "call_1")]

    items = SERIALIZER.input_items(history)

    assert_equal reasoning_item, items[1]
    assert_equal "msg_1", items[2][:id]
    assert_equal({ type: "function_call", call_id: "call_1", name: "search",
                   arguments: '{"q":"ruby"}', id: "fc_1" }, items[3])
    assert_equal({ type: "function_call_output", call_id: "call_1", output: "found it" },
                 items[4])
  end

  def test_failed_tool_results_do_not_invent_an_unsupported_wire_field
    failed = Mistri::Message.tool(content: "unavailable", tool_call_id: "call_1",
                                  tool_error: true)

    item = SERIALIZER.input_items([failed]).first

    assert_equal({ type: "function_call_output", call_id: "call_1", output: "unavailable" },
                 item)
  end

  def test_a_reasoning_item_missing_encrypted_content_is_dropped
    bare = { "type" => "reasoning", "id" => "rs_1", "summary" => [] }
    thinking = Mistri::Content::Thinking.new(thinking: "", signature: JSON.generate(bare))
    items = SERIALIZER.input_items([Mistri::Message.assistant(content: [thinking])])

    assert_empty items
  end

  def test_foreign_thinking_without_a_responses_payload_is_dropped
    anthropic_thinking = Mistri::Content::Thinking.new(thinking: "why", signature: "sig_abc")
    items = SERIALIZER.input_items([Mistri::Message.assistant(content: [anthropic_thinking])])

    assert_empty items
  end

  def test_images_ride_as_data_urls
    image = Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
    item = SERIALIZER.user_item(Mistri::Message.user(["see", image]))

    assert_equal "input_text", item[:content].first[:type]
    assert_match(%r{\Adata:image/png;base64,}, item[:content].last[:image_url])
  end
end
