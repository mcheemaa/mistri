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

  def test_only_failed_tool_results_emit_is_error
    history = [Mistri::Message.tool(content: "Error-looking success", tool_call_id: "a"),
               Mistri::Message.tool(content: "plain failure", tool_call_id: "b",
                                    tool_error: true)]

    blocks = SERIALIZER.messages(history).first[:content]

    refute blocks.first.key?(:is_error)
    assert blocks.last[:is_error]
  end

  def test_invalid_or_non_object_tool_arguments_replay_as_objects
    invalid = Mistri::ToolCall.new(id: "bad", name: "inspect", arguments: nil,
                                   arguments_error: "invalid_json")
    scalar = Mistri::ToolCall.new(id: "scalar", name: "inspect", arguments: 7)

    assert_equal({}, SERIALIZER.block(invalid)[:input])
    assert_equal({}, SERIALIZER.block(scalar)[:input])
  end

  def test_thinking_replays_with_signature_and_redacted_as_opaque_data
    thinking = Mistri::Content::Thinking.new(thinking: "why", signature: "sig")
    redacted = Mistri::Content::Thinking.new(thinking: "", signature: "opaque", redacted: true)
    wire = SERIALIZER.message(Mistri::Message.assistant(content: [thinking, redacted],
                                                        provider: :anthropic))

    assert_equal({ type: "thinking", thinking: "why", signature: "sig" }, wire[:content][0])
    assert_equal({ type: "redacted_thinking", data: "opaque" }, wire[:content][1])
  end

  def test_foreign_thinking_signatures_never_reach_the_messages_wire
    thinking = Mistri::Content::Thinking.new(thinking: "why", signature: "foreign")
    redacted = Mistri::Content::Thinking.new(thinking: "", signature: "opaque", redacted: true)
    wire = SERIALIZER.message(Mistri::Message.assistant(content: [thinking, redacted],
                                                        provider: :gemini))

    assert_equal [{ type: "text", text: "why" }], wire[:content]
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

  def test_web_search_serializes_as_the_hosted_search_tool
    wire = SERIALIZER.tools([{ name: "read", description: "d", input_schema: {} },
                             Mistri.web_search])

    assert_equal({ type: "web_search_20250305", name: "web_search" }, wire.last)
    assert_equal "read", wire.first[:name]
  end

  def test_server_tool_blocks_replay_verbatim_on_own_turns
    call = Mistri::Content::ServerToolCall.new(id: "srvtoolu_1", name: "web_search",
                                               arguments: { "query" => "ruby" })
    result = Mistri::Content::ServerToolResult.new(
      tool_call_id: "srvtoolu_1", name: "web_search",
      payload: [{ "type" => "web_search_result", "url" => "https://ruby-lang.org" }]
    )
    content = [call, result, Mistri::Content::Text.new(text: "found it")]
    history = [Mistri::Message.assistant(content: content, provider: :anthropic)]

    blocks = SERIALIZER.messages(history).first[:content]

    assert_equal({ type: "server_tool_use", id: "srvtoolu_1", name: "web_search",
                   input: { "query" => "ruby" } }, blocks[0])
    assert_equal({ type: "web_search_tool_result", tool_use_id: "srvtoolu_1",
                   content: [{ "type" => "web_search_result", "url" => "https://ruby-lang.org" }] },
                 blocks[1])
  end

  def test_server_tool_blocks_from_another_provider_drop_from_replay
    call = Mistri::Content::ServerToolCall.new(id: "ws_1", name: "web_search", arguments: {})
    history = [Mistri::Message.assistant(content: [call, Mistri::Content::Text.new(text: "hi")],
                                         provider: :openai)]

    blocks = SERIALIZER.messages(history).first[:content]

    assert_equal [{ type: "text", text: "hi" }], blocks
  end

  def test_a_server_tool_call_with_non_object_arguments_replays_as_an_empty_object
    call = Mistri::Content::ServerToolCall.new(id: "srvtoolu_2", name: "web_search",
                                               arguments: "not a hash")
    history = [Mistri::Message.assistant(content: [call], provider: :anthropic)]

    blocks = SERIALIZER.messages(history).first[:content]

    assert_equal({ type: "server_tool_use", id: "srvtoolu_2", name: "web_search", input: {} },
                 blocks[0])
  end

  def test_a_non_web_search_server_result_drops_from_replay
    result = Mistri::Content::ServerToolResult.new(tool_call_id: "srvtoolu_3",
                                                   name: "code_execution", payload: [])
    history = [Mistri::Message.assistant(content: [result, Mistri::Content::Text.new(text: "hi")],
                                         provider: :anthropic)]

    blocks = SERIALIZER.messages(history).first[:content]

    assert_equal [{ type: "text", text: "hi" }], blocks
  end
end
