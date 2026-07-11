# frozen_string_literal: true

require_relative "test_helper"

# Human-in-the-loop: a gated tool suspends the run immediately (fire and
# forget, no thread waits), the decision arrives later as a session entry
# from any process, and resume settles it and finishes the exchange.
class TestAgentApproval < Minitest::Test
  def test_a_gated_call_suspends_the_run_without_executing
    sent = []
    events = []
    agent = build_agent(sent, turns: [gift_turn, { text: "Sent!" }])

    result = agent.run("Send Ana a gift") { |event| events << event }

    assert_predicate result, :awaiting_approval?
    assert_equal "send_gift", result.pending.first.name
    assert_empty sent, "the gated tool must not execute before approval"
    assert(events.any? { |e| e.type == :approval_needed })
    refute(events.any? { |e| e.type == :tool_started })
  end

  def test_approval_days_later_from_a_fresh_process_completes_the_run
    store = Mistri::Stores::Memory.new
    sent = []
    session = Mistri::Session.new(store:)
    first = build_agent(sent, turns: [gift_turn, { text: "Sent!" }], session:)
    call = first.run("Send Ana a gift").pending.first

    # Days later, a web request records the decision with no agent at all.
    Mistri::Session.new(store:, id: session.id).approve(call.id)

    # A fresh worker resumes on the same store; its provider now only needs
    # the turn that follows the settled tool result.
    resumed = build_agent(sent, turns: [{ text: "Sent!" }],
                                session: Mistri::Session.new(store:, id: session.id))
    result = resumed.resume

    assert_predicate result, :completed?
    assert_equal "Sent!", result.text
    assert_equal [{ "to" => "Ana" }], sent
  end

  def test_a_denial_reaches_the_model_in_band
    sent = []
    agent = build_agent(sent, turns: [gift_turn, { text: "Understood, not sending." }])
    agent.run("Send Ana a gift")
    call_id = agent.session.open_approvals.first[:call].id
    agent.session.deny(call_id, note: "too expensive")

    result = agent.resume

    assert_predicate result, :completed?
    assert_empty sent
    denial = agent.session.messages.select(&:tool?).last

    assert_match(/denied/i, denial.text)
    assert_match(/too expensive/, denial.text)
    refute_predicate denial, :tool_error?, "human denial is an expected control outcome"
  end

  def test_resume_before_a_decision_returns_still_suspended
    agent = build_agent([], turns: [gift_turn])
    agent.run("Send Ana a gift")

    result = agent.resume

    assert_predicate result, :awaiting_approval?
    assert_equal "send_gift", result.pending.first.name
  end

  def test_run_refuses_while_approvals_are_open
    agent = build_agent([], turns: [gift_turn])
    agent.run("Send Ana a gift")

    assert_raises(Mistri::ConfigurationError) { agent.run("another thing") }
  end

  def test_ungated_calls_in_the_same_turn_execute_before_suspension
    log = []
    turn = { tool_calls: [{ name: "lookup", arguments: {} },
                          { name: "send_gift", arguments: { "to" => "Ana" } }] }
    provider = Mistri::Providers::Fake.new(turns: [turn])
    lookup = Mistri::Tool.define("lookup", "Free.") do
      log << :looked
      "found"
    end
    gift = gift_tool(log)
    agent = Mistri::Agent.new(provider:, tools: [lookup, gift])

    result = agent.run("go")

    assert_predicate result, :awaiting_approval?
    assert_equal [:looked], log
  end

  def test_conditional_gating_only_parks_the_risky_calls
    sent = []
    tool = Mistri::Tool.define("pay", "Pay an amount.",
                               needs_approval: ->(args) { args["amount"].to_i > 100 },
                               schema: -> { integer :amount, "Amount", required: true }) do |args|
      sent << args["amount"]
      "paid"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "pay",
                                                              arguments: { "amount" => 5 } }] },
                                             { text: "done" }
                                           ])
    result = Mistri::Agent.new(provider:, tools: [tool]).run("pay 5")

    assert_predicate result, :completed?
    assert_equal [5], sent
  end

  def test_a_raising_approval_policy_fails_closed_per_call
    ran = []
    broken = Mistri::Tool.define("broken", "B.", needs_approval: lambda { |_args|
      raise "policy unavailable"
    }) { flunk "ran despite an unavailable approval policy" }
    safe_a = Mistri::Tool.define("safe_a", "A.") do
      ran << :safe_a
      "ok"
    end
    safe_b = Mistri::Tool.define("safe_b", "B.") do
      ran << :safe_b
      "ok"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "safe_a", arguments: {} },
                                                            { name: "broken", arguments: {} },
                                                            { name: "safe_b", arguments: {} }] },
                                             { text: "done" }
                                           ])
    events = []
    agent = Mistri::Agent.new(provider:, tools: [safe_a, broken, safe_b], max_concurrency: 1)

    result = agent.run("go") { |event| events << event }

    assert_predicate result, :completed?
    assert_equal %i[safe_a safe_b], ran
    answers = agent.session.messages.select(&:tool?)

    assert_equal %w[safe_a broken safe_b], answers.map(&:tool_name)
    assert_equal [false, true, false], answers.map(&:tool_error)
    assert_includes answers[1].text, "approval policy"
    starts = events.select { |event| event.type == :tool_started }.map(&:tool_call)
    results = events.select { |event| event.type == :tool_result }.map(&:tool_call)

    assert_equal %w[safe_a safe_b], starts.map(&:name)
    assert_equal %w[safe_a broken safe_b], results.map(&:name)
    replay = provider.requests.last[:messages].select(&:tool?)

    assert_equal %w[safe_a broken safe_b], replay.map(&:tool_name)
  end

  def test_mixed_approval_decisions_settle_in_original_call_order
    ran = []
    first = Mistri::Tool.define("first", "First.", needs_approval: true) do
      flunk "denied call ran"
    end
    second = Mistri::Tool.define("second", "Second.", needs_approval: true) do
      ran << :second
      "done"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "first", arguments: {} },
                                                            { name: "second", arguments: {} }] },
                                             { text: "noted" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [first, second])
    pending = agent.run("go").pending
    agent.session.deny(pending[0].id)
    agent.session.approve(pending[1].id)
    events = []

    agent.resume { |event| events << event }

    assert_equal [:second], ran
    answers = agent.session.messages.select(&:tool?)

    assert_equal %w[first second], answers.map(&:tool_name)
    assert_equal [false, false], answers.map(&:tool_error)
    results = events.select { |event| event.type == :tool_result }

    assert_equal(%w[first second], results.map { |event| event.tool_call.name })
  end

  private

  def gift_turn
    { tool_calls: [{ name: "send_gift", arguments: { "to" => "Ana" } }] }
  end

  def gift_tool(sink)
    Mistri::Tool.define("send_gift", "Sends a real gift.", needs_approval: true,
                                                           schema: lambda {
                                                             string :to, "Recipient", required: true
                                                           }) do |args|
      sink << args
      "gift queued"
    end
  end

  def build_agent(sent, turns:, session: nil)
    provider = Mistri::Providers::Fake.new(turns: turns)
    Mistri::Agent.new(provider:, tools: [gift_tool(sent)], session:)
  end
end
