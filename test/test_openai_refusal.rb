# frozen_string_literal: true

require_relative "test_helper"

class TestOpenAIRefusal < Minitest::Test
  def test_a_structured_output_refusal_is_a_non_retryable_provider_verdict
    events = []
    item = refusal_item("I cannot help with that.")
    message = drive(events, [
                      { "type" => "response.output_item.added", "item" => item },
                      { "type" => "response.refusal.delta", "delta" => "I cannot" },
                      { "type" => "response.output_item.done", "item" => item },
                      { "type" => "response.completed",
                        "response" => { "status" => "completed" } }
                    ])

    assert_equal :error, message.stop_reason
    assert_equal "InvalidRequestError", message.error.fetch("type")
    assert_includes message.error_message, "I cannot help with that."
    refute Mistri::RetryPolicy.new.retryable?(message.error)
    assert_equal "I cannot", message.text
    assert_equal %i[text_start text_delta text_end error], events.map(&:type)
  end

  def test_a_completed_refusal_without_a_terminal_response_still_fails_fast
    item = refusal_item("No.")
    message = drive([], [
                      { "type" => "response.output_item.added", "item" => item },
                      { "type" => "response.output_item.done", "item" => item }
                    ])

    assert_equal :error, message.stop_reason
    assert_equal "InvalidRequestError", message.error.fetch("type")
    refute Mistri::RetryPolicy.new.retryable?(message.error)
    assert_includes message.error_message, "No."
  end

  def test_a_refusal_delta_is_a_verdict_even_when_the_stream_drops
    events = []
    item = refusal_item("ignored without done")
    message = drive(events, [
                      { "type" => "response.output_item.added", "item" => item },
                      { "type" => "response.refusal.delta", "delta" => "Cannot comply." }
                    ])

    assert_equal "InvalidRequestError", message.error.fetch("type")
    assert_equal "Cannot comply.", message.text
    assert_equal %i[text_start text_delta text_end error], events.map(&:type)
    refute Mistri::RetryPolicy.new.retryable?(message.error)
  end

  def test_refusal_details_are_bounded_and_encoding_safe
    item = refusal_item(("\u{1F642}" * 1024) + ("x" * 4096))
    message = drive([], [
                      { "type" => "response.output_item.added", "item" => item },
                      { "type" => "response.output_item.done", "item" => item },
                      { "type" => "response.completed",
                        "response" => { "status" => "completed" } }
                    ])

    assert_predicate message.error_message, :valid_encoding?
    assert_operator message.error_message.bytesize, :<=, 2200
  end

  private

  def refusal_item(text)
    { "type" => "message", "id" => "msg_refusal",
      "content" => [{ "type" => "refusal", "refusal" => text }] }
  end

  def drive(events, records)
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.6")
    records.each { |record| assembler.feed(record) { |event| events << event } }
    assembler.finish { |event| events << event }
  end
end
