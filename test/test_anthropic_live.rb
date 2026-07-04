# frozen_string_literal: true

require_relative "test_helper"

# Real API calls, opt-in: MISTRI_LIVE=1 bundle exec rake test
class TestAnthropicLive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?
  end

  def test_a_text_turn_streams_and_lands
    provider = Mistri::Providers::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    events = []

    message = provider.stream(
      messages: [Mistri::Message.user("Reply with exactly: mistri lives")],
      system: "You follow instructions exactly."
    ) { |event| events << event }

    assert_equal :stop, message.stop_reason
    assert_match(/mistri lives/i, message.text)
    assert events.any? { |e| e.type == :text_delta }, "expected streamed text deltas"
    assert_operator message.usage.output, :>, 0
  ensure
    provider&.close
  end

  def test_a_tool_call_turn_stops_for_tool_use_with_parsed_arguments
    provider = Mistri::Providers::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    events = []
    weather = { name: "get_weather", description: "Current weather for a city.",
                input_schema: { type: "object", properties: { city: { type: "string" } },
                                required: ["city"] } }

    message = provider.stream(
      messages: [Mistri::Message.user("What is the weather in Lahore? Use the tool.")],
      tools: [weather]
    ) { |event| events << event }

    assert_equal :tool_use, message.stop_reason
    call = message.tool_calls.first

    assert_equal "get_weather", call.name
    assert_match(/lahore/i, call.arguments["city"])
  ensure
    provider&.close
  end
end
