# frozen_string_literal: true

require_relative "test_helper"

# Real API calls, opt-in: MISTRI_LIVE=1 bundle exec rake test
class TestOpenAILive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no OPENAI_API_KEY" if ENV["OPENAI_API_KEY"].to_s.empty?
  end

  def test_a_text_turn_streams_and_lands
    provider = Mistri::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"))
    events = []

    message = provider.stream(
      messages: [Mistri::Message.user("Reply with exactly: mistri lives")],
      system: "You follow instructions exactly."
    ) { |event| events << event }

    assert_equal :stop, message.stop_reason
    assert_match(/mistri lives/i, message.text)
    assert(events.any? { |e| e.type == :text_delta })
    assert_operator message.usage.output, :>, 0
  ensure
    provider&.close
  end

  # The replay test that matters: a tool turn's reasoning and function_call
  # items must round-trip through our signatures, or the second request 400s
  # on broken pairing.
  def test_a_tool_turn_replays_cleanly_into_a_final_answer
    provider = Mistri::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"))
    weather = { name: "get_weather", description: "Current weather for a city.",
                input_schema: { type: "object", properties: { city: { type: "string" } },
                                required: ["city"], additionalProperties: false } }
    history = [Mistri::Message.user("What is the weather in Lahore? Use the tool.")]

    first = provider.stream(messages: history, tools: [weather]) { |_e| nil }

    assert_equal :tool_use, first.stop_reason
    call = first.tool_calls.first

    assert_match(/lahore/i, call.arguments["city"])

    history << first
    history << Mistri::Message.tool(content: "Sunny, 41C", tool_call_id: call.id)
    second = provider.stream(messages: history, tools: [weather]) { |_e| nil }

    assert_equal :stop, second.stop_reason
    assert_match(/41|sunny/i, second.text)
  ensure
    provider&.close
  end
end
