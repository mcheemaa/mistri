# frozen_string_literal: true

require_relative "test_helper"

# Agent#task: a run that must end in schema-valid JSON, with a fix pass when
# it does not and a loud failure when it cannot.
class TestAgentTask < Minitest::Test
  SCHEMA = { type: "object",
             properties: { "city" => { type: "string" },
                           "temperature" => { type: "number" } },
             required: %w[city temperature] }.freeze

  class NativeFallbackFake < Mistri::Providers::Fake
    attr_reader :native_schemas

    def initialize(**)
      super
      @native_schemas = []
    end

    def native_output_schema(schema)
      @native_schemas << schema
      nil
    end
  end

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
    expected = {
      "type" => "object",
      "properties" => {
        "city" => { "type" => "string" },
        "temperature" => { "type" => "number" }
      },
      "required" => %w[city temperature],
      "additionalProperties" => false
    }

    assert_equal expected, request[:options][:output_schema]
    assert_predicate request[:options][:output_schema], :frozen?
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

  def test_plain_run_does_not_apply_task_capability_fallback
    provider = NativeFallbackFake.new(turns: [{ text: "not json" }])

    Mistri::Agent.new(provider:).run("go", output_schema: SCHEMA)

    assert_empty provider.native_schemas
    assert_same SCHEMA, provider.requests.last[:options][:output_schema]
  end

  def test_task_falls_back_to_prompt_and_local_correction_without_native_schema
    provider = NativeFallbackFake.new(turns: [
                                        { text: '{"city":"Lahore"}' },
                                        { text: '{"city":"Lahore","temperature":31}' }
                                      ])

    result = Mistri::Agent.new(provider:).task("weather", schema: SCHEMA)
    output_schemas = provider.requests.map { |request| request[:options][:output_schema] }

    assert_equal 31, result.output["temperature"]
    assert_equal [nil, nil], output_schemas
    assert_equal 2, provider.native_schemas.length
    assert_same provider.native_schemas.first, provider.native_schemas.last
    assert_includes provider.requests.first[:messages].first.text, "matching this schema"
  end

  def test_oversized_task_output_is_rejected_before_json_parsing
    oversized = "x" * ((8 * 1024 * 1024) + 1)
    parsed = nil
    parse_called = false
    trace = TracePoint.new(:call) do |event|
      json_parse = event.defined_class == JSON.singleton_class && event.method_id == :parse
      parse_called = true if json_parse
    end

    trace.enable { parsed = Mistri::TaskOutput.parse(oversized) }

    refute parse_called
    assert_equal ["the answer exceeds the output byte limit"],
                 Mistri::TaskOutput.errors(parsed, SCHEMA)
  end

  def test_overwide_task_output_is_rejected_before_json_parsing
    overwide = "[#{Array.new(20_002, "0").join(",")}]"
    parsed = nil
    parse_called = false
    trace = TracePoint.new(:call) do |event|
      json_parse = event.defined_class == JSON.singleton_class && event.method_id == :parse
      parse_called = true if json_parse
    end

    trace.enable { parsed = Mistri::TaskOutput.parse(overwide) }

    refute parse_called
    assert_equal ["the answer exceeds the output complexity limit"],
                 Mistri::TaskOutput.errors(parsed, SCHEMA)
  end

  def test_task_rejects_assertions_local_validation_cannot_guarantee
    provider = Mistri::Providers::Fake.new(turns: [{ text: '{"code":"ABC"}' }])
    schema = {
      type: "object",
      properties: { code: { type: "string", pattern: "^[a-z]+$" } }
    }

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider:).task("extract", schema: schema)
    end

    assert_match(/task output schema uses assertions Mistri cannot validate/, error.message)
    assert_empty provider.requests
  end
end
