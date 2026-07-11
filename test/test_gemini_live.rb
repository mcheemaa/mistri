# frozen_string_literal: true

require_relative "test_helper"
require "securerandom"

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
    assert_operator message.usage.cost.total, :>, 0, "catalog pricing must ride live usage"
    assert_predicate message.usage.cost, :known?
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

  def test_a_nested_freeform_object_reaches_a_tool_call
    provider = Mistri::Providers::Gemini.new(api_key: ENV.fetch("GEMINI_API_KEY"))
    tool = Mistri::Tool.define("render_chart", "Renders the requested chart.", schema: lambda {
      object :config, "Chart config; include a series array.", required: true
    }) { |_args| "rendered" }

    message = provider.stream(
      messages: [Mistri::Message.user(
        'Call render_chart with config {"series":[{"type":"bar","data":[1,2]}]}. No prose.'
      )],
      tools: [tool.spec]
    ) { |_event| nil }

    assert_equal :tool_use, message.stop_reason
    config = message.tool_calls.first.arguments["config"]

    assert_kind_of Hash, config
    assert_equal "bar", config.dig("series", 0, "type")
    assert_equal [1, 2], config.dig("series", 0, "data")
  ensure
    provider&.close
  end

  def test_foreign_tool_history_projects_into_a_valid_gemini_continuation
    provider = Mistri::Providers::Gemini.new(api_key: ENV.fetch("GEMINI_API_KEY"),
                                             model: "gemini-3.5-flash")
    fact = "Mistri-cross-provider-#{SecureRandom.hex(5)}"
    call = Mistri::ToolCall.new(id: "openai-call-1", name: "lookup",
                                arguments: { "record" => "one" },
                                signature: "openai-item-1")
    history = [
      Mistri::Message.user("Look up the record."),
      Mistri::Message.assistant(content: [call], provider: :openai,
                                stop_reason: :tool_use),
      Mistri::Message.tool(content: fact, tool_call_id: call.id, tool_name: call.name),
      Mistri::Message.user("Repeat the exact historical lookup result and nothing else.")
    ]

    message = provider.stream(messages: history) { |_event| nil }

    assert_equal :stop, message.stop_reason
    assert_includes message.text, fact
  ensure
    provider&.close
  end
end
