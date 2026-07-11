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
    tool_result = agent.session.messages[2]

    assert_match(/Error running tool "boom".*kaboom/, tool_result.text)
    assert_match(/verify.*before retrying/i, tool_result.text)
    assert_predicate tool_result, :tool_error?
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
    assert_predicate tool_result, :tool_error?
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

  def test_a_cost_budget_rejects_a_provider_without_known_pricing
    provider = Mistri::Providers::OpenAI.new(api_key: "test", model: "gpt-next",
                                             service_tier: "default")

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider:, budget: Mistri::Budget.new(cost_usd: 1.00))
    end

    assert_match(/deterministic standard service tier/, error.message)
    Mistri::Agent.new(provider:)
  ensure
    provider&.close
  end

  def test_a_cost_budget_rejects_nondeterministic_service_tier_policy
    provider = Mistri::Providers::OpenAI.new(api_key: "test", service_tier: "flex")

    assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider:, budget: Mistri::Budget.new(cost_usd: 1.00))
    end
  ensure
    provider&.close
  end

  def test_a_provider_cannot_claim_pricing_then_return_unknown_cost
    provider = Mistri::Providers::Fake.new(turns: [{ text: "done" }])
    provider.define_singleton_method(:prices_usage?) { true }
    provider.define_singleton_method(:stream) do |**_options|
      Mistri::Message.assistant(content: "done", stop_reason: :stop)
    end
    agent = Mistri::Agent.new(provider:, budget: Mistri::Budget.new(cost_usd: 1.00))

    error = assert_raises(Mistri::BudgetError) { agent.run("go") }
    entry = agent.session.entries.find { |item| item["type"] == "unpriced_attempt" }

    refute_predicate error.usage.cost, :known?
    assert_equal "done", error.provider_message.text
    assert_equal "turn", entry["kind"]
  end

  def test_compaction_cost_is_checked_before_the_next_model_turn
    session = session_ready_for_compaction
    summary_usage = Mistri::Usage.new(input: 1_000_000).with_cost(input: 2.0)
    provider = Mistri::Providers::Fake.new(turns: [{ text: "## Goal\nContinue.",
                                                     usage: summary_usage },
                                                   { text: "must not run" }])
    agent = Mistri::Agent.new(provider:, session:, budget: Mistri::Budget.new(cost_usd: 1.00),
                              compaction: Mistri::Compaction.new(window: 1_000, reserve: 50,
                                                                 keep_recent: 10))

    result = agent.run("next")

    assert_predicate result, :stopped_by_budget?
    assert_equal "budget_cost", result.message.error_message
    assert_equal 1, provider.requests.length
  end

  def test_a_failed_compaction_attempt_still_counts_toward_run_usage
    failed_usage = Mistri::Usage.new(input: 1_000).with_cost(input: 1.0)
    turn_usage = Mistri::Usage.new(input: 500).with_cost(input: 1.0)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { error: "summary failed", usage: failed_usage },
                                             { text: "done", usage: turn_usage }
                                           ])
    agent = Mistri::Agent.new(provider:, session: session_ready_for_compaction,
                              budget: Mistri::Budget.new(cost_usd: 1.00),
                              compaction: compacting_settings)

    result = agent.run("next")

    assert_equal 1_500, result.usage.input
    assert_in_delta 0.0015, result.usage.cost.total
    assert_equal 2, provider.requests.length
  end

  def test_a_failed_compaction_without_usage_fails_a_cost_budget_closed
    calls = 0
    provider = Mistri::Providers::Fake.new
    provider.define_singleton_method(:stream) do |**_options|
      calls += 1
      Mistri::Message.assistant(content: "", stop_reason: :error,
                                error_message: "summary failed")
    end
    agent = Mistri::Agent.new(provider:, session: session_ready_for_compaction,
                              budget: Mistri::Budget.new(cost_usd: 1.00),
                              compaction: compacting_settings)

    error = assert_raises(Mistri::BudgetError) { agent.run("next") }
    entry = agent.session.entries.find { |item| item["type"] == "unpriced_attempt" }

    refute_predicate error.usage.cost, :known?
    assert_equal "compaction", entry["kind"]
    assert_equal 1, calls
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

  private

  def session_ready_for_compaction
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("old context " * 100))
    session.append_message(Mistri::Message.assistant(content: "old answer " * 100,
                                                     stop_reason: :stop,
                                                     usage: Mistri::Usage.new(input: 900,
                                                                              output: 100)))
    session.append_message(Mistri::Message.user("keep this"))
    session
  end

  def compacting_settings
    Mistri::Compaction.new(window: 1_000, reserve: 50, keep_recent: 10)
  end
end
