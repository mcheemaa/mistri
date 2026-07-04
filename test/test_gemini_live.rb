# frozen_string_literal: true

require_relative "test_helper"

# Real API calls, opt-in: MISTRI_LIVE=1 bundle exec rake test
class TestGeminiLive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no GEMINI_API_KEY" if ENV["GEMINI_API_KEY"].to_s.empty?
  end

  def test_a_text_turn_streams_and_lands
    provider = Mistri::Providers::Gemini.new(api_key: ENV.fetch("GEMINI_API_KEY"))
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

  # The replay test that matters on Gemini: the thought signature must echo
  # back verbatim on the functionCall part, or newer models reject the turn.
  def test_a_tool_turn_replays_cleanly_into_a_final_answer
    provider = Mistri::Providers::Gemini.new(api_key: ENV.fetch("GEMINI_API_KEY"))
    weather = { name: "get_weather", description: "Current weather for a city.",
                input_schema: { type: "object", properties: { city: { type: "string" } },
                                required: ["city"] } }
    history = [Mistri::Message.user("What is the weather in Lahore? Use the tool.")]

    first = provider.stream(messages: history, tools: [weather]) { |_e| nil }

    assert_equal :tool_use, first.stop_reason
    call = first.tool_calls.first

    assert_match(/lahore/i, call.arguments["city"])

    history << first
    history << Mistri::Message.tool(content: "Sunny, 41C", tool_call_id: call.id,
                                    tool_name: call.name)
    second = provider.stream(messages: history, tools: [weather]) { |_e| nil }

    assert_equal :stop, second.stop_reason
    assert_match(/41|sunny/i, second.text)
  ensure
    provider&.close
  end
end
