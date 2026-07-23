# frozen_string_literal: true

require_relative "test_helper"

class TestAnthropicAssembler < Minitest::Test # rubocop:disable Metrics/ClassLength -- one wire fold
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

  def test_completed_tool_arguments_preserve_non_object_json_and_omission
    { "null" => nil, "false" => false, "7" => 7, '"text"' => "text",
      '[1,{"x":true}]' => [1, { "x" => true }] }.each do |json, expected|
      message = tool_call_with(json)

      if expected.nil?
        assert_nil message.tool_calls.first.arguments
      else
        assert_equal expected, message.tool_calls.first.arguments
      end

      assert_nil message.tool_calls.first.arguments_error
    end

    assert_equal({}, tool_call_with(nil).tool_calls.first.arguments)
  end

  def test_fragmented_tool_arguments_release_the_buffer_after_the_aggregate_limit
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    deltas = []
    emit = ->(event) { deltas << event.delta if event.type == :toolcall_delta }
    assembler.feed({ "type" => "content_block_start", "index" => 0,
                     "content_block" => { "type" => "tool_use", "id" => "too-large",
                                          "name" => "inspect" } }, &emit)
    chunk = "x" * (tool_argument_limit / 2)
    fragments = ['{"blob":"', chunk, chunk, "ignored-after-overflow"]
    fragments.each do |fragment|
      assembler.feed({ "type" => "content_block_delta", "index" => 0,
                       "delta" => { "type" => "input_json_delta",
                                    "partial_json" => fragment } }, &emit)
    end

    builder = assembler.instance_variable_get(:@current)

    assert_empty builder.json, "the retained bytes are released once the cap is crossed"
    assert_equal fragments.map(&:bytesize), deltas.map(&:bytesize),
                 "resource accounting must not hide raw stream deltas"
    assert_equal fragments.first, deltas.first
    assert_equal fragments.last, deltas.last

    assembler.feed({ "type" => "content_block_stop", "index" => 0 }, &emit)
    assembler.feed({ "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" },
                     "usage" => {} })
    assembler.feed({ "type" => "message_stop" })
    call = assembler.finish.tool_calls.first

    assert_nil call.arguments
    assert_equal "too_large", call.arguments_error
  end

  def test_partial_argument_parsing_has_a_bounded_work_schedule
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    assembler.feed({ "type" => "content_block_start", "index" => 0,
                     "content_block" => { "type" => "tool_use", "id" => "bounded-preview",
                                          "name" => "inspect" } })
    previews = []
    fragments = ['{"blob":"'] + Array.new(128) { "x" * 1024 }
    fragments.each do |fragment|
      assembler.feed({ "type" => "content_block_delta", "index" => 0,
                       "delta" => { "type" => "input_json_delta",
                                    "partial_json" => fragment } })
      previews << assembler.instance_variable_get(:@current).argument_preview
    end
    builder = assembler.instance_variable_get(:@current)

    assert_operator previews.map(&:object_id).uniq.length, :<=, 21
    assert_operator builder.preview_bytes, :<=, 64 * 1024
  end

  def test_malformed_completed_tool_arguments_are_not_salvaged_from_partials
    events = []
    message = drive(events, tool_call_records('{"query":"ruby"'))
    call = message.tool_calls.first
    partial = events.find { |event| event.type == :toolcall_delta }.partial.tool_calls.first

    assert_equal({ "query" => "ruby" }, partial.arguments,
                 "the live preview may remain readable")
    assert_nil call.arguments
    assert_equal "invalid_json", call.arguments_error

    whitespace = tool_call_with("   ").tool_calls.first

    assert_nil whitespace.arguments
    assert_equal "invalid_json", whitespace.arguments_error
  end

  def test_message_stop_never_promotes_an_unfinished_tool_block
    records = tool_call_records('{"config":{"mode":"safe"}}')
    records.delete_if { |record| record["type"] == "content_block_stop" }
    events = []

    message = drive(events, records)
    call = message.tool_calls.first

    assert_equal :error, message.stop_reason
    assert_nil call.arguments
    assert_equal "incomplete", call.arguments_error
    assert_equal %i[toolcall_start toolcall_delta toolcall_end error], events.map(&:type)
    preview = events.find { |event| event.type == :toolcall_delta }.partial.tool_calls.first

    assert_predicate preview.arguments["config"], :frozen?
  end

  def test_a_truncated_text_block_closes_before_the_terminal_error
    events = []
    message = drive(events, [
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => { "type" => "text" } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "text_delta", "text" => "cut" } }
                    ])

    assert_equal "cut", message.text
    assert_equal %i[text_start text_delta text_end error], events.map(&:type)
  end

  def test_an_in_stream_error_ends_the_turn_in_band
    events = []
    message = drive(events, [
                      { "type" => "error",
                        "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }
                    ])

    assert_equal :error, message.stop_reason
    assert_equal "Mistri::OverloadedError: overloaded_error: Overloaded", message.error_message
    assert_equal "OverloadedError", message.error["type"], "overloaded classifies as retryable"
    assert_predicate events.last, :error?
  end

  def test_wire_error_types_control_retryability
    policy = Mistri::RetryPolicy.new
    cases = {
      "authentication_error" => ["AuthenticationError", false],
      "invalid_request_error" => ["InvalidRequestError", false],
      "permission_error" => ["InvalidRequestError", false],
      "future_policy_error" => ["InvalidRequestError", false],
      "rate_limit_error" => ["RateLimitError", true],
      "api_error" => ["ServerError", true],
      "timeout_error" => ["ProviderError", true],
      "overloaded_error" => ["OverloadedError", true]
    }

    cases.each do |wire_type, (error_type, retryable)|
      message = drive([], [{ "type" => "error",
                             "error" => { "type" => wire_type, "message" => "no" } }])

      assert_equal error_type, message.error["type"], wire_type
      assert_equal retryable, policy.retryable?(message.error), wire_type
    end
  end

  def test_fragmented_thinking_signatures_have_an_aggregate_ceiling
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    assembler.feed({ "type" => "content_block_start", "index" => 0,
                     "content_block" => { "type" => "thinking" } })
    fragment = "s" * (tool_argument_limit / 2)
    2.times do
      assembler.feed({ "type" => "content_block_delta", "index" => 0,
                       "delta" => { "type" => "signature_delta",
                                    "signature" => fragment } })
    end

    error = assert_raises(Mistri::ResponseTooLargeError) do
      assembler.feed({ "type" => "content_block_delta", "index" => 0,
                       "delta" => { "type" => "signature_delta", "signature" => "x" } })
    end

    assert_equal :thinking_signature, error.kind
  end

  def test_interrupted_thinking_never_replays_a_partial_signature
    message = drive([], [
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => { "type" => "thinking" } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "thinking_delta", "thinking" => "Plan" } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "signature_delta",
                                     "signature" => "partial-secret" } }
                    ])
    thinking = message.content.first
    replay = Mistri::Providers::Anthropic::Serializer.messages([message]).first

    assert_nil thinking.signature
    refute_predicate thinking, :redacted?
    assert_equal [{ type: "text", text: "Plan" }], replay[:content]
    refute(replay[:content].any? { |block| %w[thinking redacted_thinking].include?(block[:type]) })
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

  def test_folds_a_hosted_web_search_turn_into_server_tool_blocks
    events = []
    message = drive(events, [
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => { "type" => "server_tool_use", "id" => "srvtoolu_1",
                                             "name" => "web_search" } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "input_json_delta",
                                     "partial_json" => '{"query": "ruby 3.4"}' } },
                      { "type" => "content_block_stop", "index" => 0 },
                      { "type" => "content_block_start", "index" => 1,
                        "content_block" => {
                          "type" => "web_search_tool_result", "tool_use_id" => "srvtoolu_1",
                          "content" => [{ "type" => "web_search_result",
                                          "url" => "https://ruby-lang.org" }]
                        } },
                      { "type" => "content_block_stop", "index" => 1 },
                      { "type" => "content_block_start", "index" => 2,
                        "content_block" => { "type" => "text" } },
                      { "type" => "content_block_delta", "index" => 2,
                        "delta" => { "type" => "text_delta", "text" => "Released" } },
                      { "type" => "content_block_stop", "index" => 2 },
                      { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
                        "usage" => { "output_tokens" => 9 } },
                      { "type" => "message_stop" }
                    ])

    call, result, text = message.content

    assert_equal Mistri::Content::ServerToolCall.new(id: "srvtoolu_1", name: "web_search",
                                                     arguments: { "query" => "ruby 3.4" }), call
    assert_equal "srvtoolu_1", result.tool_call_id
    assert_equal [{ "type" => "web_search_result", "url" => "https://ruby-lang.org" }],
                 result.payload
    assert_equal "Released", text.text
    assert_empty message.tool_calls
    server_events = events.map(&:type).select { |type| type.start_with?("server_tool") }

    assert_equal %i[server_tool_call_start server_tool_call_end
                    server_tool_result_start server_tool_result_end], server_events
  end

  def test_a_web_search_error_result_still_folds_into_the_block
    events = []
    message = drive(events, [
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => {
                          "type" => "web_search_tool_result", "tool_use_id" => "srvtoolu_9",
                          "content" => { "type" => "web_search_tool_result_error",
                                         "error_code" => "max_uses_exceeded" }
                        } },
                      { "type" => "content_block_stop", "index" => 0 },
                      { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
                        "usage" => { "output_tokens" => 1 } },
                      { "type" => "message_stop" }
                    ])

    result = message.content.first

    assert_equal "max_uses_exceeded", result.payload["error_code"]
    assert_equal :stop, message.stop_reason
  end

  def test_a_hosted_search_with_non_object_input_degrades_to_empty_arguments
    message = drive([], [
                      { "type" => "content_block_start", "index" => 0,
                        "content_block" => { "type" => "server_tool_use", "id" => "srvtoolu_2",
                                             "name" => "web_search" } },
                      { "type" => "content_block_delta", "index" => 0,
                        "delta" => { "type" => "input_json_delta",
                                     "partial_json" => "[1, 2]" } },
                      { "type" => "content_block_stop", "index" => 0 },
                      { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
                        "usage" => { "output_tokens" => 1 } },
                      { "type" => "message_stop" }
                    ])
    call = message.content.first

    assert_equal "web_search", call.name
    assert_empty call.arguments
  end

  private

  def tool_argument_limit
    Mistri.const_get(:ToolArguments, false)::MAX_BYTES
  end

  def tool_call_with(json)
    drive([], tool_call_records(json))
  end

  def tool_call_records(json)
    records = [
      { "type" => "content_block_start", "index" => 0,
        "content_block" => { "type" => "tool_use", "id" => "toolu_args",
                             "name" => "inspect" } }
    ]
    if json
      records << { "type" => "content_block_delta", "index" => 0,
                   "delta" => { "type" => "input_json_delta", "partial_json" => json } }
    end
    records + [
      { "type" => "content_block_stop", "index" => 0 },
      { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" },
        "usage" => {} },
      { "type" => "message_stop" }
    ]
  end

  def drive(events, records)
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    emit = ->(event) { events << event }
    records.each { |record| assembler.feed(record, &emit) }
    assembler.finish(&emit)
  end
end # rubocop:enable Metrics/ClassLength
