# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestOpenAIAssembler < Minitest::Test
  def test_folds_reasoning_text_and_usage_with_replay_signatures
    events = []
    reasoning_item = { "type" => "reasoning", "id" => "rs_1",
                       "summary" => [{ "type" => "summary_text", "text" => "Think." }],
                       "encrypted_content" => "opaque123" }
    message = drive(events, [
                      { "type" => "response.output_item.added",
                        "item" => { "type" => "reasoning", "id" => "rs_1" } },
                      { "type" => "response.reasoning_summary_text.delta", "delta" => "Think." },
                      { "type" => "response.output_item.done", "item" => reasoning_item },
                      { "type" => "response.output_item.added",
                        "item" => { "type" => "message", "id" => "msg_1" } },
                      { "type" => "response.output_text.delta", "delta" => "Hello" },
                      { "type" => "response.output_item.done",
                        "item" => { "type" => "message", "id" => "msg_1",
                                    "content" => [{ "type" => "output_text",
                                                    "text" => "Hello" }] } },
                      { "type" => "response.completed",
                        "response" => {
                          "status" => "completed",
                          "usage" => { "input_tokens" => 50,
                                       "input_tokens_details" => { "cached_tokens" => 30 },
                                       "output_tokens" => 9,
                                       "output_tokens_details" => { "reasoning_tokens" => 4 } }
                        } }
                    ])

    assert_equal "Hello", message.text
    assert_equal :stop, message.stop_reason
    assert_equal reasoning_item, JSON.parse(message.content.first.signature)
    assert_equal "msg_1", message.content.last.signature
    assert_equal 20, message.usage.input
    assert_equal 30, message.usage.cache_read
    assert_equal 4, message.usage.reasoning
    assert_equal %i[thinking_start thinking_delta thinking_end],
                 events.select { |e| e.type.start_with?("thinking") }.map(&:type)
  end

  def test_a_tool_call_turn_parses_arguments_and_keeps_the_item_id
    events = []
    message = drive(events, [
                      { "type" => "response.output_item.added",
                        "item" => { "type" => "function_call", "id" => "fc_1",
                                    "call_id" => "call_1", "name" => "search" } },
                      { "type" => "response.function_call_arguments.delta",
                        "delta" => '{"q": "ru' },
                      { "type" => "response.function_call_arguments.delta", "delta" => 'by"}' },
                      { "type" => "response.output_item.done",
                        "item" => { "type" => "function_call", "id" => "fc_1",
                                    "call_id" => "call_1", "name" => "search",
                                    "arguments" => '{"q": "ruby"}' } },
                      { "type" => "response.completed",
                        "response" => { "status" => "completed", "usage" => nil } }
                    ])

    call = message.tool_calls.first

    assert_equal :tool_use, message.stop_reason
    assert_equal "call_1", call.id
    assert_equal "fc_1", call.signature
    assert_equal({ "q" => "ruby" }, call.arguments)
    mid = events.find { |e| e.type == :toolcall_delta }.partial.tool_calls.first

    assert_equal({ "q" => "ru" }, mid.arguments)
  end

  def test_incomplete_and_failed_responses_map_to_stop_reasons
    incomplete = drive([], [
                         { "type" => "response.incomplete",
                           "response" => {
                             "status" => "incomplete",
                             "incomplete_details" => { "reason" => "max_output_tokens" }
                           } }
                       ])

    assert_equal :length, incomplete.stop_reason

    failed = drive([], [
                     { "type" => "response.failed",
                       "response" => { "status" => "failed",
                                       "error" => { "message" => "server exploded" } } }
                   ])

    assert_equal :error, failed.stop_reason
    assert_equal "server exploded", failed.error_message
  end

  def test_a_stream_that_ends_without_a_terminal_event_is_an_error
    message = drive([], [{ "type" => "response.output_text.delta", "delta" => "cut off" }])

    assert_equal :error, message.stop_reason
    assert_match(/terminal event/, message.error_message)
  end

  private

  def drive(events, records)
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    emit = ->(event) { events << event }
    records.each { |record| assembler.feed(record, &emit) }
    assembler.finish(&emit)
  end
end
