# frozen_string_literal: true

require_relative "test_helper"

class TestAnthropicSerializer < Minitest::Test
  SERIALIZER = Mistri::Providers::Anthropic::Serializer

  def test_a_freeform_object_schema_passes_through
    tool = Mistri::Tool.define("render", "d", schema: lambda {
      object :config, "Open configuration", required: true
    }) { "ok" }

    wire = SERIALIZER.tools([tool.spec])

    assert_equal tool.input_schema, wire.first[:input_schema]
  end

  def test_parallel_tool_results_merge_into_one_user_turn
    call_a = Mistri::ToolCall.new(id: "a", name: "x", arguments: {})
    call_b = Mistri::ToolCall.new(id: "b", name: "y", arguments: {})
    history = [
      Mistri::Message.user("go"),
      Mistri::Message.assistant(tool_calls: [call_a, call_b], stop_reason: :tool_use),
      Mistri::Message.tool(content: "one", tool_call_id: "a"),
      Mistri::Message.tool(content: "two", tool_call_id: "b")
    ]

    wire = SERIALIZER.messages(history)

    assert_equal 3, wire.length
    results = wire.last

    assert_equal "user", results[:role]
    assert_equal(%w[a b], results[:content].map { |r| r[:tool_use_id] })
    assert_equal({ type: "tool_use", id: "a", name: "x", input: {} }, wire[1][:content].first)
  end

  def test_thinking_replays_with_signature_and_redacted_as_opaque_data
    thinking = Mistri::Content::Thinking.new(thinking: "why", signature: "sig")
    redacted = Mistri::Content::Thinking.new(thinking: "", signature: "opaque", redacted: true)
    wire = SERIALIZER.message(Mistri::Message.assistant(content: [thinking, redacted]))

    assert_equal({ type: "thinking", thinking: "why", signature: "sig" }, wire[:content][0])
    assert_equal({ type: "redacted_thinking", data: "opaque" }, wire[:content][1])
  end

  def test_cache_marks_the_system_tail_and_the_last_user_turn
    history = [Mistri::Message.user("first"), Mistri::Message.assistant(content: "hi"),
               Mistri::Message.user("second")]

    system = SERIALIZER.system_blocks("Be helpful.", cache: true)
    wire = SERIALIZER.messages(history, cache: true)

    assert_equal({ type: "ephemeral" }, system.last[:cache_control])
    assert_equal({ type: "ephemeral" }, wire.last[:content].last[:cache_control])
    refute wire.first[:content].last.key?(:cache_control)
  end

  def test_images_and_eager_tools_take_their_wire_shapes
    image = Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
    wire = SERIALIZER.message(Mistri::Message.user(["look", image]))

    assert_equal "base64", wire[:content].last[:source][:type]
    assert_equal "image/png", wire[:content].last[:source][:media_type]

    tools = SERIALIZER.tools([{ name: "write", description: "d",
                                input_schema: { type: "object" }, eager_input_streaming: true }])

    assert tools.first[:eager_input_streaming]
    refute SERIALIZER.tools([{ name: "read", description: "d", input_schema: {} }])
                     .first.key?(:eager_input_streaming)
  end
end
