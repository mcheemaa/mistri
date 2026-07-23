# frozen_string_literal: true

require_relative "test_helper"

class TestGeminiAssembler < Minitest::Test
  def test_folds_thought_and_text_parts_into_separate_blocks
    events = []
    message = drive(events, [
                      { "candidates" => [{ "content" => { "parts" => [
                        { "text" => "Considering.", "thought" => true }
                      ] } }] },
                      { "candidates" => [{ "content" => { "parts" => [{ "text" => "Hel" }] } }] },
                      { "candidates" => [{ "content" => { "parts" => [{ "text" => "lo" }] } }],
                        "usageMetadata" => { "promptTokenCount" => 30,
                                             "cachedContentTokenCount" => 10,
                                             "candidatesTokenCount" => 5,
                                             "thoughtsTokenCount" => 7 } },
                      { "candidates" => [{ "finishReason" => "STOP" }] }
                    ])

    assert_equal "Hello", message.text
    assert_equal :stop, message.stop_reason
    assert_equal %i[thinking text], message.content.map(&:type)
    assert_equal 20, message.usage.input
    assert_equal 12, message.usage.output
    assert_equal 7, message.usage.reasoning
    assert_equal %i[thinking_start thinking_delta thinking_end],
                 events.select { |e| e.type.start_with?("thinking") }.map(&:type)
  end

  def test_a_function_call_arrives_whole_with_its_thought_signature
    events = []
    message = drive(events, [
                      { "candidates" => [{ "content" => { "parts" => [
                        { "functionCall" => { "id" => "call-remote", "name" => "search",
                                              "args" => { "q" => "ruby" } },
                          "thoughtSignature" => "tsig123" }
                      ] } }] },
                      { "candidates" => [{ "finishReason" => "STOP" }] }
                    ])

    call = message.tool_calls.first

    assert_equal :tool_use, message.stop_reason
    assert_equal "search", call.name
    assert_equal "call-remote", call.id
    assert_equal "call-remote", call.provider_call_id
    assert_equal({ "q" => "ruby" }, call.arguments)
    assert_equal "tsig123", call.signature
    assert_equal %i[toolcall_start toolcall_delta toolcall_end],
                 events.select { |e| e.type.start_with?("toolcall") }.map(&:type)
  end

  def test_signed_parts_keep_their_wire_boundaries
    message = drive([], [
                      { "candidates" => [{ "content" => { "parts" => [
                        { "text" => "A", "thoughtSignature" => "sig-a" },
                        { "text" => "B", "thoughtSignature" => "sig-b" }
                      ] } }] },
                      { "candidates" => [{ "finishReason" => "STOP" }] }
                    ])

    assert_equal %w[A B], message.content.map(&:text)
    assert_equal %w[sig-a sig-b], message.content.map(&:signature)
  end

  def test_missing_function_call_ids_receive_unique_internal_ids_only
    first = function_call.tool_calls.first
    second = function_call.tool_calls.first

    refute_equal first.id, second.id
    assert_nil first.provider_call_id
    assert_nil second.provider_call_id
  end

  def test_function_calls_preserve_non_object_arguments_and_omission
    [nil, false, 7, "text", [1, { "x" => true }]].each do |value|
      call = function_call("args" => value).tool_calls.first

      value.nil? ? assert_nil(call.arguments) : assert_equal(value, call.arguments)

      assert_nil call.arguments_error
    end

    assert_equal({}, function_call.tool_calls.first.arguments)
  end

  def test_max_tokens_and_error_records_map_cleanly
    long = drive([], [
                   { "candidates" => [{ "content" => { "parts" => [{ "text" => "partial" }] },
                                        "finishReason" => "MAX_TOKENS" }] }
                 ])

    assert_equal :length, long.stop_reason
    assert_equal "partial", long.text

    failed = drive([], [{ "error" => { "code" => 500, "message" => "internal" } }])

    assert_equal :error, failed.stop_reason
    assert_equal "Mistri::ProviderError: internal | status 500", failed.error_message
    assert_equal 500, failed.error["status"], "the wire code rides as a status"
  end

  def test_max_tokens_outranks_a_function_call
    message = drive([], [
                      { "candidates" => [{
                        "content" => { "parts" => [{
                          "functionCall" => { "name" => "write", "args" => {} }
                        }] },
                        "finishReason" => "MAX_TOKENS"
                      }] }
                    ])

    assert_equal :length, message.stop_reason
    assert_equal 1, message.tool_calls.length
  end

  def test_usage_prices_from_the_catalog_and_unknown_models_stay_unknown
    message = drive([], [
                      { "candidates" => [{ "content" => { "parts" => [{ "text" => "hi" }] },
                                           "finishReason" => "STOP" }],
                        "usageMetadata" => { "promptTokenCount" => 1000,
                                             "cachedContentTokenCount" => 400,
                                             "candidatesTokenCount" => 100,
                                             "thoughtsTokenCount" => 50 } }
                    ])
    rates = Mistri::Models.rates("gemini-2.5-flash")
    expected = ((rates[:input] * 600) + (rates[:cache_read] * 400) +
                (rates[:output] * 150)) / 1_000_000.0

    assert_operator message.usage.cost.total, :>, 0
    assert_predicate message.usage.cost, :known?
    assert_in_delta expected, message.usage.cost.total, 1e-9

    unknown = Mistri::Providers::Gemini::Assembler.new(model: "gemini-hypothetical")
    unknown.feed({ "candidates" => [{ "finishReason" => "STOP" }],
                   "usageMetadata" => { "promptTokenCount" => 1000,
                                        "candidatesTokenCount" => 200 } })

    refute_predicate unknown.finish.usage.cost, :known?

    unpriced = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-flash",
                                                        catalog_pricing: false)
    unpriced.feed({ "candidates" => [{ "finishReason" => "STOP" }],
                    "usageMetadata" => { "promptTokenCount" => 1000,
                                         "candidatesTokenCount" => 200 } })

    refute_predicate unpriced.finish.usage.cost, :known?

    missing = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-flash")
    missing.feed({ "candidates" => [{ "finishReason" => "STOP" }] })

    refute_predicate missing.finish.usage.cost, :known?
  end

  def test_pro_usage_is_priced_at_the_higher_request_tier
    assembler = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-pro")
    assembler.feed({ "candidates" => [{ "finishReason" => "STOP" }],
                     "usageMetadata" => { "promptTokenCount" => 200_001,
                                          "candidatesTokenCount" => 100 } })
    usage = assembler.finish.usage

    assert_in_delta 0.5000025, usage.cost.input, 1e-9
    assert_in_delta 0.0015, usage.cost.output, 1e-9
  end

  def test_nonstandard_service_tier_usage_is_unknown
    assembler = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-flash")
    assembler.feed({ "candidates" => [{ "finishReason" => "STOP" }],
                     "usageMetadata" => { "promptTokenCount" => 1000,
                                          "candidatesTokenCount" => 100,
                                          "serviceTier" => "priority" } })

    refute_predicate assembler.finish.usage.cost, :known?

    requested = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-flash",
                                                         service_tier: "flex")
    requested.feed({ "candidates" => [{ "finishReason" => "STOP" }],
                     "usageMetadata" => { "promptTokenCount" => 1000,
                                          "candidatesTokenCount" => 100 } })

    refute_predicate requested.finish.usage.cost, :known?
  end

  def test_a_truncated_stream_keeps_partial_dollars_but_marks_them_unknown
    assembler = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-flash")
    assembler.feed({ "usageMetadata" => { "promptTokenCount" => 1000,
                                          "candidatesTokenCount" => 100,
                                          "serviceTier" => "standard" } })

    message = assembler.finish

    assert_equal :error, message.stop_reason
    assert_operator message.usage.cost.total, :>, 0
    refute_predicate message.usage.cost, :known?
  end

  # Verdict finish reasons are the provider's ruling on the content; the
  # loop must fail fast instead of re-rolling against the filter. Fumbles
  # and unknown stops (OTHER is documented as "Unknown reason") accuse the
  # input of nothing, so they error retryably instead.
  def test_blocked_finish_reasons_classify_as_verdicts_or_fumbles
    policy = Mistri::RetryPolicy.new
    %w[SAFETY RECITATION LANGUAGE BLOCKLIST PROHIBITED_CONTENT SPII IMAGE_SAFETY].each do |reason|
      message = drive([], [
                        { "candidates" => [{ "content" => { "parts" => [{ "text" => "par" }] } }] },
                        { "candidates" => [{ "finishReason" => reason }] }
                      ])

      assert_equal :error, message.stop_reason, "#{reason} must not read as a clean stop"
      assert_equal "InvalidRequestError", message.error["type"], "#{reason} misclassified"
      assert_includes message.error_message, reason
      assert_equal "par", message.text, "partial content stays readable for the host"
      refute policy.retryable?(message.error), "#{reason} is a verdict, never retried"
    end

    %w[MALFORMED_FUNCTION_CALL TOO_MANY_TOOL_CALLS OTHER MALFORMED_RESPONSE
       FINISH_REASON_UNSPECIFIED].each do |reason|
      fumble = drive([], [{ "candidates" => [{ "finishReason" => reason }] }])

      assert_equal :error, fumble.stop_reason, "#{reason} must not read as a clean stop"
      assert_equal "ProviderError", fumble.error["type"], "#{reason} misclassified"
      assert policy.retryable?(fumble.error), "#{reason} accuses the input of nothing"
    end

    missing_signature = drive([], [
                                { "candidates" => [
                                  { "finishReason" => "MISSING_THOUGHT_SIGNATURE" }
                                ] }
                              ])

    assert_equal "InvalidRequestError", missing_signature.error["type"]
    refute policy.retryable?(missing_signature.error)
  end

  def test_a_blocked_prompt_fails_fast_instead_of_reading_as_truncation
    message = drive([], [{ "promptFeedback" => { "blockReason" => "SAFETY" } }])

    assert_equal :error, message.stop_reason
    assert_equal "InvalidRequestError", message.error["type"]
    assert_includes message.error_message, "SAFETY"
    refute Mistri::RetryPolicy.new.retryable?(message.error),
           "a blocked prompt meets the same filter on every retry"

    unspecified = drive([], [
                          { "candidates" => [{ "content" => { "parts" => [{ "text" => "hi" }] } }],
                            "promptFeedback" => { "blockReason" => "BLOCK_REASON_UNSPECIFIED" } },
                          { "candidates" => [{ "finishReason" => "STOP" }] }
                        ])

    assert_equal :stop, unspecified.stop_reason, "the unused default value is not a block"
  end

  def test_an_undocumented_finish_reason_still_reads_as_stop
    message = drive([], [
                      { "candidates" => [{ "content" => { "parts" => [{ "text" => "hi" }] } }] },
                      { "candidates" => [{ "finishReason" => "SOME_FUTURE_REASON" }] }
                    ])

    assert_equal :stop, message.stop_reason, "unknown wire values stay tolerated by contract"
  end

  def test_a_stream_that_ends_without_a_finish_reason_is_an_error
    events = []
    message = drive(events, [
                      { "candidates" => [{ "content" => { "parts" => [{ "text" => "cut" }] } }] }
                    ])

    assert_equal :error, message.stop_reason
    assert_match(/finish reason/, message.error_message)
    assert_equal %i[text_start text_delta text_end error], events.map(&:type)
  end

  def test_grounding_metadata_folds_into_a_server_tool_result_block
    events = []
    grounding = { "webSearchQueries" => ["ruby 3.4 release"],
                  "groundingChunks" => [{ "web" => { "uri" => "https://ruby-lang.org" } }] }
    message = drive(events, [
                      { "candidates" => [{ "content" => {
                        "parts" => [{ "text" => "Released" }]
                      } }] },
                      { "candidates" => [{ "content" => { "parts" => [] },
                                           "groundingMetadata" => grounding,
                                           "finishReason" => "STOP" }],
                        "usageMetadata" => { "promptTokenCount" => 4,
                                             "candidatesTokenCount" => 2 } }
                    ])

    text, result = message.content

    assert_equal "Released", text.text
    assert_equal "google_search", result.name
    assert_equal grounding, result.payload
    assert_equal :stop, message.stop_reason
    server_events = events.map(&:type).select { |type| type.start_with?("server_tool") }

    assert_equal %i[server_tool_result_start server_tool_result_end], server_events
  end

  private

  def function_call(fields = {})
    drive([], [
            { "candidates" => [{ "content" => { "parts" => [
              { "functionCall" => { "name" => "inspect" }.merge(fields) }
            ] } }] },
            { "candidates" => [{ "finishReason" => "STOP" }] }
          ])
  end

  def drive(events, records)
    assembler = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-flash")
    emit = ->(event) { events << event }
    records.each { |record| assembler.feed(record, &emit) }
    assembler.finish(&emit)
  end
end
