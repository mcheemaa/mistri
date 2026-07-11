# frozen_string_literal: true

require_relative "test_helper"

class TestEvent < Minitest::Test
  def test_unknown_type_raises
    assert_raises(ArgumentError) { Mistri::Event.new(type: :telepathy) }
  end

  def test_terminal_events_are_done_and_error
    done = Mistri::Event.new(type: :done, reason: :stop)
    error = Mistri::Event.new(type: :error, reason: :error, error_message: "boom")

    assert_predicate done, :terminal?
    assert_predicate error, :terminal?
    refute_predicate Mistri::Event.new(type: :text_delta, delta: "hi"), :terminal?
  end

  def test_events_pattern_match_for_sink_routing
    event = Mistri::Event.new(type: :text_delta, content_index: 0, delta: "Hel")

    result = case event
             in Mistri::Event(type: :text_delta, delta:) then delta
             end

    assert_equal "Hel", result
  end

  def test_serialization_drops_the_partial_snapshot
    partial = Mistri::Message.assistant(content: "He")
    event = Mistri::Event.new(type: :text_delta, content_index: 0, delta: "He", partial:)

    refute_includes event.to_h.keys, :partial
    assert_equal "He", event.to_h[:delta]
  end

  def test_tool_lifecycle_events_keep_terminal_errors_distinct
    call = Mistri::ToolCall.new(id: "c1", name: "lookup", arguments: {})
    started = Mistri::Event.new(type: :tool_started, tool_call: call)
    failed = Mistri::Event.new(type: :tool_result, tool_call: call, tool_error: true)

    refute_predicate started, :terminal?
    refute_predicate failed, :error?
    assert failed.to_h[:tool_error]
  end

  def test_tool_error_is_boolean_and_only_belongs_to_results
    assert_raises(ArgumentError) do
      Mistri::Event.new(type: :tool_result)
    end
    assert_raises(ArgumentError) do
      Mistri::Event.new(type: :tool_result, tool_error: "yes")
    end
    assert_raises(ArgumentError) do
      Mistri::Event.new(type: :tool_started, tool_error: false)
    end
    message = Mistri::Message.tool(content: "failed", tool_call_id: "c1", tool_error: true)

    assert_raises(ArgumentError) do
      Mistri::Event.new(type: :tool_result, message:, tool_error: false)
    end
  end
end
