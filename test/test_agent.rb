# frozen_string_literal: true

require_relative "test_helper"

class TestAgent < Minitest::Test
  def test_runs_a_tool_then_answers_persisting_the_whole_exchange
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "add",
                                                              arguments: { "a" => 2,
                                                                           "b" => 3 } }] },
                                             { text: "The sum is 5." }
                                           ])
    add = Mistri::Tool.define("add", "Add two numbers.") { |args| (args["a"] + args["b"]).to_s }
    agent = Mistri::Agent.new(provider:, tools: [add])

    message = agent.run("What is 2 plus 3?")

    assert_equal "The sum is 5.", message.text
    assert_equal :stop, message.stop_reason
    roles = agent.session.messages.map(&:role)

    assert_equal %i[user assistant tool assistant], roles
    assert_equal "5", agent.session.messages[2].text
  end

  def test_the_second_provider_call_sees_the_tool_result
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "ping", arguments: {} }] },
                                             { text: "done" }
                                           ])
    ping = Mistri::Tool.define("ping", "Ping.") { "pong" }
    Mistri::Agent.new(provider:, tools: [ping]).run("go")

    second_call_history = provider.requests.last[:messages].map(&:role)

    assert_equal %i[user assistant tool], second_call_history
  end

  def test_a_failing_tool_feeds_an_in_band_error_back_to_the_model
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "boom", arguments: {} }] },
                                             { text: "recovered" }
                                           ])
    boom = Mistri::Tool.define("boom", "Explodes.") { raise "kaboom" }
    agent = Mistri::Agent.new(provider:, tools: [boom])

    agent.run("go")
    tool_result = agent.session.messages[2].text

    assert_match(/Error running tool "boom".*kaboom/, tool_result)
  end

  def test_an_errored_turn_with_tool_calls_pairs_without_executing
    turn = { tool_calls: [{ name: "danger", arguments: {} }], stop_reason: :error }
    provider = Mistri::Providers::Fake.new(turns: [turn])
    danger = Mistri::Tool.define("danger", "Must not run.") { flunk "executed on an errored turn" }
    agent = Mistri::Agent.new(provider:, tools: [danger])

    message = agent.run("go")

    assert_equal :error, message.stop_reason
    tool_result = agent.session.messages.last

    assert_predicate tool_result, :tool?
    assert_equal Mistri::ToolExecutor::INTERRUPTED, tool_result.text
  end

  def test_a_budget_stops_the_run_between_turns
    provider = Mistri::Providers::Fake.new(turns: Array.new(5) do
      { tool_calls: [{ name: "loop", arguments: {} }] }
    end)
    tool = Mistri::Tool.define("loop", "Loops.") { "again" }
    agent = Mistri::Agent.new(provider:, tools: [tool], budget: Mistri::Budget.new(turns: 2))

    message = agent.run("go")

    assert_equal :budget, message.stop_reason
    assert_equal "budget_turns", message.error_message
  end

  def test_a_cost_budget_stops_the_run_between_turns
    priced = Mistri::Usage.new(input: 200_000, output: 10_000)
                          .with_cost(input: 5.0, output: 25.0)
    provider = Mistri::Providers::Fake.new(turns: Array.new(3) do
      { tool_calls: [{ name: "loop", arguments: {} }], usage: priced }
    end)
    tool = Mistri::Tool.define("loop", "Loops.") { "again" }
    agent = Mistri::Agent.new(provider:, tools: [tool],
                              budget: Mistri::Budget.new(cost_usd: 1.00))

    message = agent.run("go")

    assert_equal :budget, message.stop_reason
    assert_equal "budget_cost", message.error_message
  end

  def test_empty_input_and_duplicate_tools_fail_loudly
    provider = Mistri::Providers::Fake.new
    ping = Mistri::Tool.define("ping", "Ping.") { "pong" }

    assert_raises(ArgumentError) { Mistri::Agent.new(provider:).run("") }
    assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider:, tools: [ping, ping])
    end
  end

  def test_events_stream_through_to_the_caller
    provider = Mistri::Providers::Fake.new(turns: [{ text: "hello there" }])
    types = []

    Mistri::Agent.new(provider:).run("hi") { |event| types << event.type }

    assert_equal :start, types.first
    assert_includes types, :text_delta
    assert_equal :done, types.last
  end

  def test_streaming_a_tool_turn_emits_tool_results_between_turns
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "ping", arguments: {} }] },
                                             { text: "done" }
                                           ])
    ping = Mistri::Tool.define("ping", "Ping.") { "pong" }
    events = []

    Mistri::Agent.new(provider:, tools: [ping]).run("go") { |event| events << event }

    result = events.find { |e| e.type == :tool_result }

    assert_equal "ping", result.tool_call.name
    assert_equal "pong", result.content
    assert_equal :done, events.last.type
  end

  def test_a_result_reports_the_runs_usage
    turn_usage = Mistri::Usage.new(input: 100, output: 20)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "noop", arguments: {} }],
                                               usage: turn_usage },
                                             { text: "done", usage: turn_usage }
                                           ])
    noop = Mistri::Tool.define("noop", "N.") { "ok" }

    result = Mistri::Agent.new(provider:, tools: [noop]).run("go")

    assert_equal 200, result.usage.input
    assert_equal 40, result.usage.output
  end

  def test_a_task_sums_usage_across_fix_passes
    turn_usage = Mistri::Usage.new(input: 50, output: 5)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: "not json", usage: turn_usage },
                                             { text: '{"x":1}', usage: turn_usage }
                                           ])
    schema = { type: "object", properties: { "x" => { type: "integer" } }, required: ["x"] }

    result = Mistri::Agent.new(provider:).task("go", schema: schema)

    assert_equal 1, result.output["x"]
    assert_equal 100, result.usage.input, "both passes count"
  end
end
