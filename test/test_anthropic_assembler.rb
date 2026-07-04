# frozen_string_literal: true

require_relative "test_helper"

class TestAnthropicAssembler < Minitest::Test
  def test_folds_a_thinking_text_turn_with_usage_and_signature
    events = []
    message = drive(events, [
                      { "type" => "message_start",
                        "message" => { "usage" => { "input_tokens" => 40,
                                                    "cache_read_input_tokens" => 900 } } },
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => { "type" => "thinking" } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "thinking_delta", "thinking" => "Plan it." } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "signature_delta", "signature" => "sig123" } },
                      { "type" => "content_block_stop", "index" => 0 },
                      { "type" => "content_block_start", "index" => 1,
                        "content_block" => { "type" => "text" } },
                      { "type" => "content_block_delta", "index" => 1,
                        "delta" => { "type" => "text_delta", "text" => "Hello" } },
                      { "type" => "content_block_stop", "index" => 1 },
                      { "type" => "ping" },
                      { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
                        "usage" => { "output_tokens" => 12 } },
                      { "type" => "message_stop" }
                    ])

    assert_equal "Hello", message.text
    assert_equal "sig123", message.content.first.signature
    assert_equal :stop, message.stop_reason
    assert_equal 40, message.usage.input
    assert_equal 900, message.usage.cache_read
    assert_equal 12, message.usage.output
    assert_equal :done, events.last.type
    assert_equal %i[thinking_start thinking_delta thinking_end],
                 events.select { |e| e.type.start_with?("thinking") }.map(&:type)
  end

  def test_tool_arguments_parse_partially_mid_stream_and_fully_at_the_end
    events = []
    message = drive(events, [
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => { "type" => "tool_use", "id" => "toolu_1",
                                             "name" => "search" } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "input_json_delta",
                                     "partial_json" => '{"query": "ru' } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "input_json_delta", "partial_json" => 'by"}' } },
                      { "type" => "content_block_stop", "index" => 0 },
                      { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" },
                        "usage" => {} },
                      { "type" => "message_stop" }
                    ])

    mid_stream = events.find { |e| e.type == :toolcall_delta }.partial.tool_calls.first

    assert_equal({ "query" => "ru" }, mid_stream.arguments)
    assert_equal({ "query" => "ruby" }, message.tool_calls.first.arguments)
    assert_equal "toolu_1", message.tool_calls.first.id
    assert_equal :tool_use, message.stop_reason
  end

  def test_an_in_stream_error_ends_the_turn_in_band
    events = []
    message = drive(events, [
                      { "type" => "error",
                        "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }
                    ])

    assert_equal :error, message.stop_reason
    assert_equal "Mistri::OverloadedError: Overloaded", message.error_message
    assert_equal "OverloadedError", message.error["type"], "overloaded classifies as retryable"
    assert_predicate events.last, :error?
  end

  def test_redacted_thinking_and_unknown_events_are_handled
    message = drive([], [
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => { "type" => "redacted_thinking", "data" => "opaque" } },
                      { "type" => "content_block_stop", "index" => 0 },
                      { "type" => "some_future_event" },
                      { "type" => "message_stop" }
                    ])

    assert_predicate message.content.first, :redacted?
    assert_equal "opaque", message.content.first.signature
  end

  def test_a_provider_error_folds_with_its_status_and_body
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    error = Mistri::ServerError.new(status: 503, body: "upstream connect timeout")

    message = assembler.fail_stream(error)

    assert_match(/status 503/, message.error_message)
    assert_match(/upstream connect timeout/, message.error_message)
  end

  private

  def drive(events, records)
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    emit = ->(event) { events << event }
    records.each { |record| assembler.feed(record, &emit) }
    assembler.finish(&emit)
  end
end
