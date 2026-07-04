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
    denial = agent.session.messages.select(&:tool?).last.text

    assert_match(/denied/i, denial)
    assert_match(/too expensive/, denial)
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
                               needs_approval: ->(args) { args["amount"].to_i > 100 }) do |args|
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
