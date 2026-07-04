# frozen_string_literal: true

require_relative "test_helper"

# The whole loop against a real provider: prompt, tool call, result, answer.
class TestAgentLive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?
  end

  def test_the_agent_calls_a_tool_and_answers_from_its_result
    provider = Mistri::Providers::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    calls = []
    weather = Mistri::Tool.define("get_weather", "Current weather for a city.", schema: lambda {
      string :city, "City name", required: true
    }) do |args|
      calls << args["city"]
      "Sunny, 41C"
    end
    agent = Mistri::Agent.new(provider:, tools: [weather])

    message = agent.run("Weather in Lahore? Use the tool, then answer in one sentence.")

    assert_match(/lahore/i, calls.first)
    assert_equal :stop, message.stop_reason
    assert_match(/41|sunny/i, message.text)
    assert_equal %i[user assistant tool assistant], agent.session.messages.map(&:role)
  ensure
    provider&.close
  end
end
