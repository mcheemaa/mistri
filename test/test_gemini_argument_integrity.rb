# frozen_string_literal: true

require_relative "test_helper"
require "delegate"

class TestGeminiArgumentIntegrity < Minitest::Test
  class GeminiFake < SimpleDelegator
    def stream(**, &)
      super.with(provider: :gemini)
    end
  end

  class VerdictGemini
    attr_reader :requests

    def initialize(message)
      @message = message
      @requests = 0
    end

    def model = "gemini-verdict"

    def stream(**, &emit)
      @requests += 1
      emit&.call(Mistri::Event.new(type: :error, reason: @message.stop_reason,
                                   message: @message, error_message: @message.error_message))
      @message
    end
  end

  def test_malformed_gemini_calls_retry_without_persisting_unreplayable_history
    invalid_calls = [
      { id: "bad-json", name: "write", arguments: {},
        arguments_error: "invalid_json", signature: "signed" },
      { id: "wrong-shape", name: "write", arguments: [], signature: "signed" }
    ]

    invalid_calls.each do |invalid|
      fake = Mistri::Providers::Fake.new(turns: [
                                           { tool_calls: [invalid] },
                                           { text: "recovered" }
                                         ])
      provider = GeminiFake.new(fake)
      retries = Mistri::RetryPolicy.new(attempts: 1, base: 0, max_delay: 0)
      ran = false
      tool = Mistri::Tool.define("write", "Writes.") do
        ran = true
        "written"
      end
      agent = Mistri::Agent.new(provider:, tools: [tool], retries:)

      result = agent.run("go")

      assert_predicate result, :completed?
      refute ran
      assert_equal 2, provider.requests.length
      assert_equal provider.requests[0][:messages].map(&:to_h),
                   provider.requests[1][:messages].map(&:to_h)
      assert_empty agent.session.messages.flat_map(&:tool_calls)
      assert_equal(1, agent.session.entries.count { |entry| entry["type"] == "retry" })
    end
  end

  def test_malformed_call_metadata_cannot_reclassify_a_provider_verdict
    call = Mistri::ToolCall.new(id: "bad", name: "write", arguments: {},
                                arguments_error: "invalid_json", signature: "signed")
    message = Mistri::Message.assistant(
      content: ["blocked", call], provider: :gemini, model: "gemini-verdict",
      usage: Mistri::Usage.zero, stop_reason: :error,
      error_message: "generation stopped: SAFETY",
      error: { "type" => "InvalidRequestError" }
    )
    provider = VerdictGemini.new(message)
    tool = Mistri::Tool.define("write", "Writes.") { flunk "verdict call executed" }

    result = Mistri::Agent.new(provider:, tools: [tool]).run("go")

    assert_predicate result, :errored?
    assert_equal 1, provider.requests
    assert_equal "InvalidRequestError", result.message.error.fetch("type")
    assert_empty result.message.tool_calls
    assert_equal "blocked", result.text
    assert_predicate result.message.content, :frozen?
    assert_raises(FrozenError) { result.message.content << "mutated" }
  end
end
