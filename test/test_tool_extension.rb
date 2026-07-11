# frozen_string_literal: true

require_relative "test_helper"

class TestToolExtension < Minitest::Test
  class DuckTool
    attr_reader :name, :timeout

    def initialize(log)
      @name = "duck"
      @timeout = nil
      @log = log
    end

    def spec
      { "name" => name, "description" => "Duck tool.",
        "input_schema" => {
          type: "object", properties: { count: { type: "integer" } }, required: ["count"]
        } }
    end

    def call(arguments, _context)
      @log << arguments.fetch("count")
      "ok"
    end

    def needs_approval?(_arguments) = false

    def ends_turn? = false
  end

  class SelfValidatingDuckTool < DuckTool
    def prepared_argument_violations(_arguments) = []
  end

  def test_agent_execution_keeps_the_historical_call_override_extension_point
    subclass = Class.new(Mistri::Tool) do
      attr_reader :observed

      def call(arguments, context = Mistri::ToolContext.new)
        @observed = [arguments, context]
        super
      end
    end
    normalizations = 0
    tool = subclass.new(
      name: "wrapped", description: "Wrapped.",
      argument_normalizer: lambda { |arguments|
        normalizations += 1
        arguments
      }
    ) { "ok" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [
                                               { name: "wrapped", arguments: {} }
                                             ] },
                                             { text: "done" }
                                           ])

    agent = Mistri::Agent.new(provider:, tools: [tool])
    result = agent.run("go")

    assert_predicate result, :completed?
    assert_equal 1, normalizations
    assert_equal({}, tool.observed.first)
    assert_predicate tool.observed.first, :frozen?
    assert_predicate tool.observed.last, :arguments_prepared?
  end

  def test_direct_executor_calls_apply_a_tool_normalizer_once
    observed = []
    normalizations = 0
    tool = Mistri::Tool.define(
      "wrapped", "Wrapped.",
      argument_normalizer: lambda { |arguments|
        normalizations += 1
        { "value" => arguments.fetch("alias") }
      }
    ) { |arguments| observed << arguments.fetch("value") }
    call = Mistri::ToolCall.new(id: "call-1", name: "wrapped",
                                arguments: { "alias" => "kept" })

    results = Mistri::ToolExecutor.call([call], { "wrapped" => tool })

    assert_equal 3, results.first.length
    assert_equal 1, normalizations
    assert_equal ["kept"], observed
  end

  def test_duck_typed_tools_keep_their_call_protocol_and_gain_core_validation
    handled = []
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [
                                               { name: "duck", arguments: { count: "two" } }
                                             ] },
                                             { tool_calls: [
                                               { name: "duck", arguments: { count: 2 } }
                                             ] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [DuckTool.new(handled)])

    result = agent.run("go")

    assert_predicate result, :completed?
    assert_equal [2], handled
    answers = agent.session.messages.select(&:tool?)

    assert_predicate answers.first, :tool_error?
    refute_predicate answers.last, :tool_error?
  end

  def test_duck_validator_cannot_bypass_the_portable_core_contract
    handled = []
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [
                                               { name: "duck",
                                                 arguments: { count: "two" } }
                                             ] },
                                             { text: "done" }
                                           ])
    tool = SelfValidatingDuckTool.new(handled)

    agent = Mistri::Agent.new(provider:, tools: [tool])
    result = agent.run("go")

    assert_predicate result, :completed?
    assert_empty handled
    assert_predicate agent.session.messages.find(&:tool?), :tool_error?
  end

  def test_tool_subclass_cannot_override_the_agent_core_contract
    subclass = Class.new(Mistri::Tool) do
      def prepared_argument_violations(_arguments) = []
    end
    handled = []
    tool = subclass.new(
      name: "strict", description: "Strict.",
      input_schema: {
        type: "object", properties: { count: { type: "integer" } }, required: ["count"]
      }
    ) { |arguments| handled << arguments }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [
                                               { name: "strict",
                                                 arguments: { count: "two" } }
                                             ] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool])

    result = agent.run("go")

    assert_predicate result, :completed?
    assert_empty handled
    assert_predicate agent.session.messages.find(&:tool?), :tool_error?
  end
end
