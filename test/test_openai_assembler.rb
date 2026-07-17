# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestOpenAIAssembler < Minitest::Test # rubocop:disable Metrics/ClassLength -- one wire fold
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

  def test_completed_tool_arguments_preserve_non_object_json
    { "null" => nil, "false" => false, "7" => 7, '"text"' => "text",
      '[1,{"x":true}]' => [1, { "x" => true }] }.each do |json, expected|
      call = tool_call_item("arguments" => json).tool_calls.first

      expected.nil? ? assert_nil(call.arguments) : assert_equal(expected, call.arguments)

      assert_nil call.arguments_error
    end
  end

  def test_malformed_completed_tool_arguments_are_not_salvaged_from_partials
    events = []
    item = { "type" => "function_call", "id" => "fc_bad", "call_id" => "call_bad",
             "name" => "inspect", "arguments" => '{"query":"ruby"' }
    message = drive(events, [
                      { "type" => "response.output_item.added", "item" => item },
                      { "type" => "response.function_call_arguments.delta",
                        "delta" => '{"query":"ruby"' },
                      { "type" => "response.output_item.done", "item" => item },
                      { "type" => "response.completed",
                        "response" => { "status" => "completed" } }
                    ])
    partial = events.find { |event| event.type == :toolcall_delta }.partial.tool_calls.first
    call = message.tool_calls.first

    assert_equal({ "query" => "ruby" }, partial.arguments,
                 "the live preview may remain readable")
    assert_nil call.arguments
    assert_equal "invalid_json", call.arguments_error

    non_string = tool_call_item("arguments" => nil).tool_calls.first
    missing = tool_call_item.tool_calls.first

    assert_nil non_string.arguments
    assert_equal "invalid_json", non_string.arguments_error
    assert_nil missing.arguments
    assert_equal "invalid_json", missing.arguments_error
  end

  def test_completed_tool_arguments_are_bounded_during_strict_parsing
    nested = nil
    66.times { nested = [nested] }
    encoded = JSON.generate(nested, max_nesting: false)

    call = tool_call_item("arguments" => encoded).tool_calls.first

    assert_nil call.arguments
    assert_equal "too_deep", call.arguments_error
  end

  def test_completed_item_supersedes_a_fragmented_argument_overflow
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    deltas = []
    emit = ->(event) { deltas << event.delta if event.type == :toolcall_delta }
    item = { "type" => "function_call", "id" => "fc_large", "call_id" => "call_large",
             "name" => "inspect" }
    assembler.feed({ "type" => "response.output_item.added", "item" => item }, &emit)
    chunk = "x" * (tool_argument_limit / 2)
    fragments = ['{"blob":"', chunk, chunk, "ignored-after-overflow"]
    fragments.each do |fragment|
      assembler.feed({ "type" => "response.function_call_arguments.delta",
                       "delta" => fragment }, &emit)
    end

    builder = assembler.instance_variable_get(:@current)

    assert_empty builder.json, "the retained bytes are released once the cap is crossed"
    assert_equal fragments.map(&:bytesize), deltas.map(&:bytesize),
                 "resource accounting must not hide raw stream deltas"
    assert_equal fragments.first, deltas.first
    assert_equal fragments.last, deltas.last

    assembler.feed({ "type" => "response.output_item.done",
                     "item" => item.merge("arguments" => '{"mode":"safe"}') }, &emit)
    assembler.feed({ "type" => "response.completed",
                     "response" => { "status" => "completed" } })
    call = assembler.finish.tool_calls.first

    assert_equal({ "mode" => "safe" }, call.arguments)
    assert_nil call.arguments_error
  end

  def test_missing_completed_arguments_preserve_a_stream_overflow
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    item = { "type" => "function_call", "id" => "fc_large", "call_id" => "call_large",
             "name" => "inspect" }
    assembler.feed({ "type" => "response.output_item.added", "item" => item })
    chunk = "x" * (tool_argument_limit / 2)
    assembler.feed({ "type" => "response.function_call_arguments.delta",
                     "delta" => '{"blob":"' })
    2.times do
      assembler.feed({ "type" => "response.function_call_arguments.delta", "delta" => chunk })
    end
    assembler.feed({ "type" => "response.output_item.done", "item" => item })
    assembler.feed({ "type" => "response.completed",
                     "response" => { "status" => "completed" } })
    call = assembler.finish.tool_calls.first

    assert_nil call.arguments
    assert_equal "too_large", call.arguments_error
  end

  def test_partial_argument_parsing_has_a_bounded_work_schedule
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    assembler.feed({ "type" => "response.output_item.added",
                     "item" => { "type" => "function_call" } })
    previews = []
    fragments = ['{"blob":"'] + Array.new(128) { "x" * 1024 }
    fragments.each do |fragment|
      assembler.feed({ "type" => "response.function_call_arguments.delta",
                       "delta" => fragment })
      previews << assembler.instance_variable_get(:@current).argument_preview
    end
    builder = assembler.instance_variable_get(:@current)

    assert_operator previews.map(&:object_id).uniq.length, :<=, 21
    assert_operator builder.preview_bytes, :<=, 64 * 1024
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

  def test_unknown_incomplete_reasons_never_read_as_a_clean_stop
    policy = Mistri::RetryPolicy.new
    [nil, "future_reason"].each do |reason|
      details = reason && { "reason" => reason }
      message = drive([], [
                        { "type" => "response.output_item.added",
                          "item" => { "type" => "message", "id" => "msg_partial" } },
                        { "type" => "response.output_text.delta", "delta" => "partial" },
                        { "type" => "response.output_item.done",
                          "item" => { "type" => "message", "id" => "msg_partial",
                                      "content" => [{ "type" => "output_text",
                                                      "text" => "partial" }] } },
                        { "type" => "response.incomplete",
                          "response" => { "status" => "incomplete",
                                          "incomplete_details" => details } }
                      ])

      assert_equal :error, message.stop_reason, reason.inspect
      assert_equal "partial", message.text, reason.inspect
      assert_equal "TruncatedStream", message.error["type"], reason.inspect
      assert policy.retryable?(message.error), "#{reason.inspect} should be retryable"
    end
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

  def test_top_level_stream_errors_classify_by_their_error_code
    policy = Mistri::RetryPolicy.new
    cases = {
      "rate_limit_exceeded" => ["RateLimitError", true],
      "server_error" => ["ServerError", true],
      "vector_store_timeout" => ["ProviderError", true],
      "invalid_prompt" => ["InvalidRequestError", false],
      "image_content_policy_violation" => ["InvalidRequestError", false],
      "future_transient_error" => ["InvalidRequestError", false]
    }

    cases.each do |code, (type, retryable)|
      message = drive([], [{ "type" => "error", "code" => code, "message" => "no" }])

      assert_equal type, message.error["type"], code
      assert_equal retryable, policy.retryable?(message.error), code
    end

    unknown = drive([], [{ "type" => "error", "message" => "unknown transport failure" }])

    assert_equal "ProviderError", unknown.error["type"]
    assert policy.retryable?(unknown.error)
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

  def test_usage_separates_cache_reads_and_writes_from_uncached_input
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.6-luna")
    assembler.feed({ "type" => "response.completed",
                     "response" => {
                       "status" => "completed",
                       "service_tier" => "default",
                       "usage" => {
                         "input_tokens" => 1000,
                         "input_tokens_details" => {
                           "cached_tokens" => 400,
                           "cache_write_tokens" => 300
                         },
                         "output_tokens" => 100
                       }
                     } })
    usage = assembler.finish.usage
    rates = Mistri::Models.rates("gpt-5.6-luna", usage:)

    assert_equal 300, usage.input
    assert_equal 400, usage.cache_read
    assert_equal 300, usage.cache_write
    assert_equal 1000, usage.prompt_tokens
    assert_equal 1100, usage.total_tokens
    assert_predicate usage.cost, :known?
    assert_in_delta rates[:cache_write] * 300 / 1_000_000.0,
                    usage.cost.cache_write, 1e-9
    expected = ((rates[:input] * 300) + (rates[:cache_read] * 400) +
                (rates[:cache_write] * 300) + (rates[:output] * 100)) / 1_000_000.0

    assert_in_delta expected, usage.cost.total, 1e-9
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
    events = []
    message = drive(events, [
                      { "type" => "response.output_item.added",
                        "item" => { "type" => "message", "id" => "msg_cut" } },
                      { "type" => "response.output_text.delta", "delta" => "cut off" }
                    ])

    assert_equal :error, message.stop_reason
    assert_match(/terminal event/, message.error_message)
    assert_equal "cut off", message.text
    assert_equal %i[text_start text_delta text_end error], events.map(&:type)
  end

  def test_an_incomplete_stream_never_promotes_partial_arguments_to_a_final_call
    events = []
    message = drive(events, [
                      { "type" => "response.output_item.added",
                        "item" => { "type" => "function_call", "id" => "fc_cut",
                                    "call_id" => "call_cut", "name" => "inspect" } },
                      { "type" => "response.function_call_arguments.delta",
                        "delta" => '{"config":{"mode":"partial"' }
                    ])
    call = message.tool_calls.first
    preview = events.find { |event| event.type == :toolcall_delta }.partial.tool_calls.first

    assert_equal :error, message.stop_reason
    assert_nil call.arguments
    assert_equal "incomplete", call.arguments_error
    assert_predicate preview.arguments["config"], :frozen?
    assert_equal %i[toolcall_start toolcall_delta toolcall_end error], events.map(&:type)
  end

  def test_a_terminal_response_without_a_finished_function_call_is_an_error
    events = []
    message = drive(events, [
                      { "type" => "response.output_item.added",
                        "item" => { "type" => "function_call", "id" => "fc_cut",
                                    "call_id" => "call_cut", "name" => "inspect" } },
                      { "type" => "response.function_call_arguments.delta", "delta" => "{}" },
                      { "type" => "response.completed",
                        "response" => { "status" => "completed" } }
                    ])
    call = message.tool_calls.first

    assert_equal :error, message.stop_reason
    assert_match(/output_item.done/, message.error_message)
    assert_equal "incomplete", call.arguments_error
    assert_equal %i[toolcall_start toolcall_delta toolcall_end error], events.map(&:type)
  end

  def test_folds_a_web_search_call_into_a_server_tool_block
    events = []
    item = { "type" => "web_search_call", "id" => "ws_1", "status" => "completed",
             "action" => { "type" => "search", "query" => "ruby 3.4" } }
    message = drive(events, [
                      { "type" => "response.output_item.added", "output_index" => 0,
                        "item" => { "type" => "web_search_call", "id" => "ws_1" } },
                      { "type" => "response.output_item.done", "output_index" => 0,
                        "item" => item },
                      { "type" => "response.output_item.added", "output_index" => 1,
                        "item" => { "type" => "message", "id" => "msg_1" } },
                      { "type" => "response.output_text.delta", "output_index" => 1,
                        "item_id" => "msg_1", "delta" => "Released" },
                      { "type" => "response.output_item.done", "output_index" => 1,
                        "item" => { "type" => "message", "id" => "msg_1",
                                    "content" => [{ "type" => "output_text",
                                                    "text" => "Released" }] } },
                      { "type" => "response.completed",
                        "response" => { "status" => "completed",
                                        "usage" => { "input_tokens" => 5,
                                                     "output_tokens" => 7 } } }
                    ])

    call, text = message.content

    assert_equal "ws_1", call.id
    assert_equal "web_search", call.name
    assert_equal({ "type" => "search", "query" => "ruby 3.4" }, call.arguments)
    assert_equal item, JSON.parse(call.signature)
    assert_equal "Released", text.text
    assert_empty message.tool_calls
    assert_equal :stop, message.stop_reason
    server_events = events.map(&:type).select { |type| type.start_with?("server_tool") }

    assert_equal %i[server_tool_call_start server_tool_call_end], server_events
  end

  def test_a_web_search_call_without_an_action_object_degrades_to_empty_arguments
    item = { "type" => "web_search_call", "id" => "ws_2", "status" => "completed" }
    message = drive([], [
                      { "type" => "response.output_item.added", "output_index" => 0,
                        "item" => { "type" => "web_search_call", "id" => "ws_2" } },
                      { "type" => "response.output_item.done", "output_index" => 0,
                        "item" => item },
                      { "type" => "response.completed",
                        "response" => { "status" => "completed" } }
                    ])
    call = message.content.first

    assert_equal "web_search", call.name
    assert_empty call.arguments
    assert_equal item, JSON.parse(call.signature)
  end

  def test_an_interrupted_web_search_call_keeps_its_place_without_a_signature
    events = []
    message = drive(events, [
                      { "type" => "response.output_item.added", "output_index" => 0,
                        "item" => { "type" => "web_search_call", "id" => "ws_3" } },
                      { "type" => "error", "code" => "server_error", "message" => "boom" }
                    ])
    call = message.content.first

    assert_equal "web_search", call.name
    assert_empty call.arguments
    assert_nil call.signature
    assert_equal :error, message.stop_reason
    server_events = events.map(&:type).select { |type| type.start_with?("server_tool") }

    assert_equal %i[server_tool_call_start server_tool_call_end], server_events
  end

  private

  def tool_argument_limit
    Mistri.const_get(:ToolArguments, false)::MAX_BYTES
  end

  def tool_call_item(fields = {})
    item = { "type" => "function_call", "id" => "fc_args", "call_id" => "call_args",
             "name" => "inspect" }.merge(fields)
    drive([], [
            { "type" => "response.output_item.added", "item" => item },
            { "type" => "response.output_item.done", "item" => item },
            { "type" => "response.completed", "response" => { "status" => "completed" } }
          ])
  end

  def drive(events, records)
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    emit = ->(event) { events << event }
    records.each { |record| assembler.feed(record, &emit) }
    assembler.finish(&emit)
  end
end # rubocop:enable Metrics/ClassLength
