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
                        { "functionCall" => { "name" => "search", "args" => { "q" => "ruby" } },
                          "thoughtSignature" => "tsig123" }
                      ] } }] },
                      { "candidates" => [{ "finishReason" => "STOP" }] }
                    ])

    call = message.tool_calls.first

    assert_equal :tool_use, message.stop_reason
    assert_equal "search", call.name
    assert_equal({ "q" => "ruby" }, call.arguments)
    assert_equal "tsig123", call.signature
    assert_equal %i[toolcall_start toolcall_delta toolcall_end],
                 events.select { |e| e.type.start_with?("toolcall") }.map(&:type)
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

  def test_usage_prices_from_the_catalog_and_unknown_models_stay_zero
    message = drive([], [
                      { "candidates" => [{ "content" => { "parts" => [{ "text" => "hi" }] } }],
                        "usageMetadata" => { "promptTokenCount" => 1000,
                                             "cachedContentTokenCount" => 400,
                                             "candidatesTokenCount" => 100,
                                             "thoughtsTokenCount" => 50 } },
                      { "candidates" => [{ "finishReason" => "STOP" }] }
                    ])
    rates = Mistri::Models.rates("gemini-2.5-flash")
    expected = ((rates[:input] * 600) + (rates[:cache_read] * 400) +
                (rates[:output] * 150)) / 1_000_000.0

    assert_operator message.usage.cost.total, :>, 0
    assert_in_delta expected, message.usage.cost.total, 1e-9

    unknown = Mistri::Providers::Gemini::Assembler.new(model: "gemini-hypothetical")
    unknown.feed({ "candidates" => [{ "finishReason" => "STOP" }],
                   "usageMetadata" => { "promptTokenCount" => 1000,
                                        "candidatesTokenCount" => 200 } })

    assert_in_delta 0.0, unknown.finish.usage.cost.total
  end

  # Verdict finish reasons are the provider's ruling on the content; the
  # loop must fail fast instead of re-rolling against the filter. Fumbles
  # (the model botched its own output) stay retryable.
  def test_blocked_finish_reasons_classify_as_verdicts_or_fumbles
    policy = Mistri::RetryPolicy.new
    %w[SAFETY RECITATION LANGUAGE BLOCKLIST PROHIBITED_CONTENT SPII OTHER].each do |reason|
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

    fumble = drive([], [{ "candidates" => [{ "finishReason" => "MALFORMED_FUNCTION_CALL" }] }])

    assert_equal :error, fumble.stop_reason
    assert_equal "ProviderError", fumble.error["type"]
    assert policy.retryable?(fumble.error), "a fumbled function call retries"
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
    message = drive([], [
                      { "candidates" => [{ "content" => { "parts" => [{ "text" => "cut" }] } }] }
                    ])

    assert_equal :error, message.stop_reason
    assert_match(/finish reason/, message.error_message)
  end

  private

  def drive(events, records)
    assembler = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-flash")
    emit = ->(event) { events << event }
    records.each { |record| assembler.feed(record, &emit) }
    assembler.finish(&emit)
  end
end
