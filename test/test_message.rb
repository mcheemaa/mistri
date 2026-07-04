# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestMessage < Minitest::Test
  def test_user_text_stays_a_one_liner
    message = Mistri::Message.user("hi there")

    assert_predicate message, :user?
    assert_equal "hi there", message.text
  end

  def test_assistant_turn_carries_tool_calls_in_content_order
    call = Mistri::ToolCall.new(id: "call_1", name: "search", arguments: { "q" => "x" })
    message = Mistri::Message.assistant(content: "Looking that up.", tool_calls: [call],
                                        stop_reason: :tool_use)

    assert_predicate message, :tool_calls?
    assert_equal [call], message.tool_calls
    assert_equal %i[text tool_call], message.content.map(&:type)
  end

  def test_assistant_metadata_survives_a_json_round_trip
    message = Mistri::Message.assistant(
      content: "done", model: "claude-opus-4-8", provider: :anthropic,
      usage: Mistri::Usage.new(input: 10, output: 5), stop_reason: :stop
    )

    restored = Mistri::Message.from_h(JSON.parse(JSON.generate(message.to_h)))

    assert_equal message, restored
  end

  def test_tool_result_links_back_to_its_call
    message = Mistri::Message.tool(content: "42", tool_call_id: "call_1", tool_name: "calc")

    assert_predicate message, :tool?
    assert_equal "call_1", message.tool_call_id
  end

  def test_text_is_nil_on_a_pure_tool_call_turn
    call = Mistri::ToolCall.new(id: "c", name: "ping", arguments: {})

    assert_nil Mistri::Message.assistant(tool_calls: [call]).text
  end

  def test_invalid_role_and_stop_reason_raise
    assert_raises(ArgumentError) { Mistri::Message.new(role: :robot) }
    assert_raises(ArgumentError) { Mistri::Message.assistant(content: "x", stop_reason: :tired) }
  end
end
