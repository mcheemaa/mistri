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

  def test_summary_parts_stay_separate_paragraphs
    events = []
    reasoning_item = { "type" => "reasoning", "id" => "rs_2",
                       "summary" => [
                         { "type" => "summary_text", "text" => "**Sizing the data**\nSmall." },
                         { "type" => "summary_text", "text" => "**Planning charts**\nThree." }
                       ] }
    message = drive(events, [
                      { "type" => "response.output_item.added",
                        "item" => { "type" => "reasoning", "id" => "rs_2" } },
                      { "type" => "response.reasoning_summary_text.delta",
                        "delta" => "**Sizing the data**\nSmall.", "summary_index" => 0 },
                      { "type" => "response.reasoning_summary_text.delta",
                        "delta" => "**Planning charts**\nThree.", "summary_index" => 1 },
                      { "type" => "response.output_item.done", "item" => reasoning_item },
                      { "type" => "response.completed",
                        "response" => { "status" => "completed" } }
                    ])

    thinking = message.content.first

    assert_equal "**Sizing the data**\nSmall.\n\n**Planning charts**\nThree.",
                 thinking.thinking
    deltas = events.select { |e| e.type == :thinking_delta }.map(&:delta)

    assert_includes deltas, "\n\n", "the paragraph break streams live"
    assert_equal thinking.thinking, deltas.join, "streamed deltas equal the finished text"
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

  def test_a_content_filter_cut_fails_fast_instead_of_reading_complete
    message = drive([], [
                      { "type" => "response.incomplete",
                        "response" => {
                          "status" => "incomplete",
                          "incomplete_details" => { "reason" => "content_filter" }
                        } }
                    ])

    assert_equal :error, message.stop_reason
    assert_equal "InvalidRequestError", message.error["type"]
    refute Mistri::RetryPolicy.new.retryable?(message.error),
           "a filter verdict is not a truncation"
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
    assert_match(/server exploded/, failed.error_message)
  end

  # A failed response is the provider's verdict, not a dropped stream: its
  # code decides retryability, and it must never read as TruncatedStream.
  def test_failed_responses_classify_by_their_error_code
    { "rate_limit_exceeded" => "RateLimitError",
      "server_error" => "ServerError",
      "vector_store_timeout" => "ProviderError",
      "invalid_prompt" => "InvalidRequestError",
      "image_content_policy_violation" => "InvalidRequestError" }.each do |code, type|
      failed = drive([], [
                       { "type" => "response.failed",
                         "response" => { "status" => "failed",
                                         "error" => { "code" => code, "message" => "no" } } }
                     ])

      assert_equal :error, failed.stop_reason
      assert_equal type, failed.error["type"], "#{code} misclassified"
      assert_includes failed.error_message, code
    end

    bare = drive([], [{ "type" => "response.failed",
                        "response" => { "status" => "failed" } }])

    assert_equal :error, bare.stop_reason, "failure without an error object is not a clean stop"
    assert_equal "ProviderError", bare.error["type"]

    terse = drive([], [{ "type" => "response.failed",
                         "response" => { "status" => "failed",
                                         "error" => { "code" => "invalid_prompt" } } }])

    assert_includes terse.error_message, "the response failed"
  end

  def test_usage_prices_from_the_catalog_and_unknown_models_stay_unknown
    message = drive([], [
                      { "type" => "response.completed",
                        "response" => {
                          "status" => "completed",
                          "service_tier" => "default",
                          "usage" => { "input_tokens" => 1000,
                                       "input_tokens_details" => { "cached_tokens" => 400 },
                                       "output_tokens" => 200 }
                        } }
                    ])
    rates = Mistri::Models.rates("gpt-5.5")
    expected = ((rates[:input] * 600) + (rates[:cache_read] * 400) +
                (rates[:output] * 200)) / 1_000_000.0

    assert_operator message.usage.cost.total, :>, 0
    assert_predicate message.usage.cost, :known?
    assert_in_delta expected, message.usage.cost.total, 1e-9

    unknown = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-hypothetical")
    unknown.feed({ "type" => "response.completed",
                   "response" => { "status" => "completed",
                                   "usage" => { "input_tokens" => 1000,
                                                "output_tokens" => 200 } } })

    refute_predicate unknown.finish.usage.cost, :known?

    unpriced = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5",
                                                        catalog_pricing: false)
    unpriced.feed({ "type" => "response.completed",
                    "response" => { "status" => "completed",
                                    "usage" => { "input_tokens" => 1000,
                                                 "output_tokens" => 200 } } })

    refute_predicate unpriced.finish.usage.cost, :known?

    missing = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    missing.feed({ "type" => "response.completed", "response" => { "status" => "completed" } })

    refute_predicate missing.finish.usage.cost, :known?

    flex = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    flex.feed({ "type" => "response.completed",
                "response" => { "status" => "completed", "service_tier" => "flex",
                                "usage" => { "input_tokens" => 1000, "output_tokens" => 200 } } })

    refute_predicate flex.finish.usage.cost, :known?
  end

  def test_long_context_usage_is_priced_at_the_higher_request_tier
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    assembler.feed({ "type" => "response.completed",
                     "response" => { "status" => "completed", "service_tier" => "default",
                                     "usage" => { "input_tokens" => 272_001,
                                                  "output_tokens" => 100 } } })
    usage = assembler.finish.usage

    assert_in_delta 2.72001, usage.cost.input, 1e-9
    assert_in_delta 0.0045, usage.cost.output, 1e-9
  end

  def test_usage_without_a_reported_service_tier_is_unknown
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    assembler.feed({ "type" => "response.completed",
                     "response" => { "status" => "completed",
                                     "usage" => { "input_tokens" => 1000 } } })

    refute_predicate assembler.finish.usage.cost, :known?
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
