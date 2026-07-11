# frozen_string_literal: true

require_relative "test_helper"

# Real API calls, opt-in: MISTRI_LIVE=1 bundle exec rake test
class TestAnthropicLive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?
  end

  def test_a_text_turn_streams_and_lands
    provider = Mistri::Providers::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"),
                                                service_tier: "standard_only")
    events = []

    message = provider.stream(
      messages: [Mistri::Message.user("Reply with exactly: mistri lives")],
      system: "You follow instructions exactly."
    ) { |event| events << event }

    assert_equal :stop, message.stop_reason
    assert_match(/mistri lives/i, message.text)
    assert events.any? { |e| e.type == :text_delta }, "expected streamed text deltas"
    assert_operator message.usage.output, :>, 0
    assert_operator message.usage.cost.total, :>, 0, "catalog pricing must ride live usage"
    assert_predicate message.usage.cost, :known?
  ensure
    provider&.close
  end

  def test_a_tool_call_turn_stops_for_tool_use_with_parsed_arguments
    provider = Mistri::Providers::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"),
                                                service_tier: "standard_only")
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

  def test_a_nested_freeform_object_reaches_a_tool_call
    provider = Mistri::Providers::Anthropic.new(
      api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: "claude-haiku-4-5-20251001"
    )
    tool = Mistri::Tool.define("render_chart", "Renders the requested chart.", schema: lambda {
      object :config, "Chart config; include a series array.", required: true
    }) { |_args| "rendered" }

    message = provider.stream(
      messages: [Mistri::Message.user(
        'Call render_chart with config {"series":[{"type":"bar","data":[1,2]}]}.'
      )],
      tools: [tool.spec], tool_choice: { type: "tool", name: "render_chart" }
    ) { |_event| nil }

    assert_equal :tool_use, message.stop_reason
    config = message.tool_calls.first.arguments["config"]

    assert_kind_of Hash, config
    assert_equal "bar", config.dig("series", 0, "type")
    assert_equal [1, 2], config.dig("series", 0, "data")
  ensure
    provider&.close
  end
end
