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

  def test_usage_prices_from_the_catalog_and_unknown_models_stay_unknown
    message = drive([], [
                      { "type" => "message_start",
                        "message" => { "usage" => { "input_tokens" => 1000,
                                                    "cache_read_input_tokens" => 2000,
                                                    "service_tier" => "standard" } } },
                      { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
                        "usage" => { "output_tokens" => 500 } },
                      { "type" => "message_stop" }
                    ])
    rates = Mistri::Models.rates("claude-opus-4-8")
    expected = ((rates[:input] * 1000) + (rates[:cache_read] * 2000) +
                (rates[:output] * 500)) / 1_000_000.0

    assert_operator message.usage.cost.total, :>, 0
    assert_predicate message.usage.cost, :known?
    assert_in_delta expected, message.usage.cost.total,
                    1e-9, "the delta's output count must be repriced, not left stale"

    unknown = Mistri::Providers::Anthropic::Assembler.new(model: "claude-next-9000")
    unknown.feed({ "type" => "message_start",
                   "message" => { "usage" => { "input_tokens" => 1000 } } })
    unknown.feed({ "type" => "message_stop" })

    refute_predicate unknown.finish.usage.cost, :known?
  end

  def test_usage_is_unknown_without_catalog_pricing_or_wire_usage
    unpriced = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8",
                                                           catalog_pricing: false)
    unpriced.feed({ "type" => "message_start",
                    "message" => { "usage" => { "input_tokens" => 1000 } } })
    unpriced.feed({ "type" => "message_stop" })

    refute_predicate unpriced.finish.usage.cost, :known?

    missing = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    missing.feed({ "type" => "message_stop" })

    refute_predicate missing.finish.usage.cost, :known?
  end

  def test_priority_service_tier_usage_is_unknown
    priority = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    priority.feed({ "type" => "message_start",
                    "message" => { "usage" => { "input_tokens" => 1000,
                                                "service_tier" => "priority" } } })
    priority.feed({ "type" => "message_stop" })

    refute_predicate priority.finish.usage.cost, :known?
  end

  def test_usage_without_a_reported_service_tier_is_unknown
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    assembler.feed({ "type" => "message_start",
                     "message" => { "usage" => { "input_tokens" => 1000 } } })
    assembler.feed({ "type" => "message_stop" })

    refute_predicate assembler.finish.usage.cost, :known?
  end

  def test_a_truncated_stream_keeps_partial_dollars_but_marks_them_unknown
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    assembler.feed({ "type" => "message_start",
                     "message" => { "usage" => { "input_tokens" => 1000,
                                                 "service_tier" => "standard" } } })

    message = assembler.finish

    assert_equal :error, message.stop_reason
    assert_operator message.usage.cost.total, :>, 0
    refute_predicate message.usage.cost, :known?
  end

  def test_message_stop_without_final_output_usage_is_unpriced
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    assembler.feed({ "type" => "message_start",
                     "message" => { "usage" => { "input_tokens" => 1000,
                                                 "service_tier" => "standard" } } })
    assembler.feed({ "type" => "message_stop" })

    message = assembler.finish

    assert_equal :stop, message.stop_reason
    assert_equal 0, message.usage.output
    refute_predicate message.usage.cost, :known?
  end

  # The API's own guidance for a refusal is a different model, never a
  # retry of this one; the machine-readable type keeps the loop from
  # re-rolling against a policy verdict.
  def test_a_refusal_fails_fast_with_its_policy_category
    events = []
    message = drive(events, [
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => { "type" => "text" } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "text_delta", "text" => "I can" } },
                      { "type" => "content_block_stop", "index" => 0 },
                      { "type" => "message_delta",
                        "delta" => { "stop_reason" => "refusal",
                                     "stop_details" => { "category" => "harmful_content",
                                                         "explanation" => "Declined." } },
                        "usage" => { "output_tokens" => 2 } },
                      { "type" => "message_stop" }
                    ])

    assert_equal :error, message.stop_reason
    assert_equal "InvalidRequestError", message.error["type"]
    assert_includes message.error_message, "harmful_content"
    assert_includes message.error_message, "Declined."
    assert_equal "I can", message.text, "partial content stays readable for the host"
    refute Mistri::RetryPolicy.new.retryable?(message.error)
    assert_predicate events.last, :error?

    bare = drive([], [
                   { "type" => "message_delta", "delta" => { "stop_reason" => "refusal" },
                     "usage" => {} },
                   { "type" => "message_stop" }
                 ])

    assert_match(/refused to respond/, bare.error_message,
                 "a refusal without stop_details still reads as a refusal")
  end

  def test_a_filled_context_window_reads_as_length
    message = drive([], [
                      { "type" => "message_delta",
                        "delta" => { "stop_reason" => "model_context_window_exceeded" },
                        "usage" => { "output_tokens" => 9 } },
                      { "type" => "message_stop" }
                    ])

    assert_equal :length, message.stop_reason, "the API says treat the response as truncated"
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
