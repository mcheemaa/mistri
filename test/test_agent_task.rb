# frozen_string_literal: true

require_relative "test_helper"

# Agent#task: a run that must end in schema-valid JSON, with a fix pass when
# it does not and a loud failure when it cannot.
class TestAgentTask < Minitest::Test
  SCHEMA = { type: "object",
             properties: { "city" => { type: "string" },
                           "temperature" => { type: "number" } },
             required: %w[city temperature] }.freeze

  def test_a_valid_answer_returns_its_parsed_output
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: '{"city":"Lahore","temperature":31.5}' }
                                           ])

    result = Mistri::Agent.new(provider:).task("weather in lahore", schema: SCHEMA)

    assert_predicate result, :completed?
    assert_equal({ "city" => "Lahore", "temperature" => 31.5 }, result.output)
  end

  def test_the_schema_reaches_the_provider_and_the_prompt
    provider = Mistri::Providers::Fake.new(turns: [{ text: '{"city":"x","temperature":1}' }])

    Mistri::Agent.new(provider:).task("weather", schema: SCHEMA)

    request = provider.requests.last

    assert_equal SCHEMA, request[:options][:output_schema]
    assert_includes request[:messages].first.text, "matching this schema"
  end

  def test_a_violation_goes_back_to_the_model_once_and_recovers
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: '{"city":"Lahore"}' },
                                             { text: '{"city":"Lahore","temperature":31}' }
                                           ])
    agent = Mistri::Agent.new(provider:)

    result = agent.task("weather", schema: SCHEMA)

    assert_equal 31, result.output["temperature"]
    assert_equal 2, provider.requests.length

    fix = provider.requests.last[:messages].select(&:user?).last.text

    assert_includes fix, "$.temperature is required"
  end

  def test_exhausted_fixes_raise_a_schema_error
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: "not json at all" },
                                             { text: "still not json" }
                                           ])

    error = assert_raises(Mistri::SchemaError) do
      Mistri::Agent.new(provider:).task("weather", schema: SCHEMA, fixes: 1)
    end

    assert_match(/not valid JSON/, error.message)
  end

  def test_fenced_json_is_tolerated
    fenced = "```json\n{\"city\":\"x\",\"temperature\":2}\n```"
    provider = Mistri::Providers::Fake.new(turns: [{ text: fenced }])

    result = Mistri::Agent.new(provider:).task("weather", schema: SCHEMA)

    assert_equal 2, result.output["temperature"]
  end

  def test_a_suspended_task_returns_without_validating
    gated = Mistri::Tool.define("send", "Sends.", needs_approval: true) { "sent" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send", arguments: {} }] }
                                           ])

    result = Mistri::Agent.new(provider:, tools: [gated]).task("send then report", schema: SCHEMA)

    assert_predicate result, :awaiting_approval?
    assert_nil result.output
  end

  def test_plain_run_with_output_schema_constrains_but_never_validates
    provider = Mistri::Providers::Fake.new(turns: [{ text: "not json" }])

    result = Mistri::Agent.new(provider:).run("go", output_schema: SCHEMA)

    assert_predicate result, :completed?
    assert_equal "not json", result.text
    assert_equal SCHEMA, provider.requests.last[:options][:output_schema]
  end
end
