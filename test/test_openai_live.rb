# frozen_string_literal: true

require "securerandom"
require_relative "test_helper"

# Real API calls, opt-in: MISTRI_LIVE=1 bundle exec rake test
class TestOpenAILive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no OPENAI_API_KEY" if ENV["OPENAI_API_KEY"].to_s.empty?
  end

  def test_a_text_turn_streams_and_lands
    provider = Mistri::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"),
                                             model: "gpt-5.6",
                                             service_tier: "default")
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

  # The replay test that matters: a tool turn's reasoning and function_call
  # items must round-trip through our signatures, or the second request 400s
  # on broken pairing.
  def test_a_tool_turn_replays_cleanly_into_a_final_answer
    provider = Mistri::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"),
                                             model: "gpt-5.6",
                                             service_tier: "default")
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

  def test_a_nested_freeform_object_schema_is_accepted
    provider = Mistri::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"),
                                             model: "gpt-5.5")
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
  ensure
    provider&.close
  end

  def test_gpt_5_6_cache_writes_are_accounted
    provider = Mistri::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"),
                                             model: "gpt-5.6-luna",
                                             reasoning: { effort: "none" },
                                             service_tier: "default")
    prompt = [SecureRandom.hex(16), "Mistri cache accounting probe. " * 700,
              "Reply with exactly: ok"].join(" ")
    messages = [Mistri::Message.user(prompt)]

    message = provider.stream(messages:)

    assert_operator message.usage.cache_write, :>, 0
    assert_operator message.usage.cost.cache_write, :>, 0
    assert_predicate message.usage.cost, :known?
  ensure
    provider&.close
  end

  def test_a_hosted_web_search_turn_folds_search_blocks_and_answers
    provider = Mistri::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"),
                                             model: "gpt-5.6")
    events = []

    message = provider.stream(
      messages: [Mistri::Message.user(
        "Search the web for the current stable Ruby version and answer in one sentence."
      )],
      tools: [Mistri.web_search]
    ) { |event| events << event }

    assert_equal :stop, message.stop_reason
    assert message.content.any?(Mistri::Content::ServerToolCall),
           "expected a server tool call block from the hosted search"
    assert events.any? { |e| e.type == :server_tool_call_start },
           "expected a server tool event"
    assert_empty message.tool_calls, "a hosted search must not surface executable calls"
  ensure
    provider&.close
  end
end
