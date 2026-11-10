# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/session_stores"
require_relative "support/session_scripts"

# A decision that passed its check and reaches the store late: after its call
# was settled and compacted away, and after a newer call took the same id.
# It decides nothing, breaks nothing, and its caller learns it lost.
class TestSessionLateDecisions < Minitest::Test
  include SessionScripts

  def setup = start

  def teardown = finish

  def test_a_late_decision_for_a_call_that_was_compacted_away_is_ignored
    call_id = agent({ tool_calls: [{ name: "gated", arguments: {} }] }).run("go").pending.first.id
    hold(:deny, call_id)
    @session.approve(call_id)
    agent({ text: "done" }).resume
    exchange("later")
    compact
    @store.release

    assert_the_late_decision_lost
    assert_operator @session.last_compaction["kept_from"], :>, 3
    assert_empty fresh.open_approvals
    assert_predicate agent({ text: "on" }).run("carry on"), :completed?
    assert_equal 1, @ran
  end

  # The newer call appends six entries over its life: its user message, the
  # assistant turn, the request, the decision, the result and the answer.
  def test_a_late_approval_decides_nothing_wherever_it_lands_in_a_newer_call_with_the_same_id
    (1..6).each do |arrival|
      deny_and_compact_while_an_approval_is_held
      land_after(arrival)
      parked = agent(ask).run("second")
      still = agent.resume
      @session.approve("same-id")
      done = agent({ text: "done" }).resume

      assert_the_late_decision_lost
      assert_equal %i[awaiting_approval awaiting_approval completed],
                   [parked, still, done].map(&:status), "arrival #{arrival}"
      assert_equal 1, @ran, "arrival #{arrival}"
      assert_empty fresh.open_approvals
      finish
      start
    end
  end

  def test_a_late_approval_is_ignored_wherever_it_lands_in_a_newer_call_that_needs_no_approval
    plain = { tool_calls: [{ id: "same-id", name: "ping", arguments: {} }] }
    (1..4).each do |arrival|
      deny_and_compact_while_an_approval_is_held
      land_after(arrival)
      result = agent(plain, { text: "done" }).run("second")

      assert_the_late_decision_lost
      assert_predicate result, :completed?, "arrival #{arrival}"
      assert_empty fresh.open_approvals
      assert_equal 0, @ran, "arrival #{arrival}"
      finish
      start
    end
  end

  private

  def start
    @store = SessionStores::HeldDecision.new
    @session = Mistri::Session.new(store: @store, id: "s")
    @ran = 0
  end

  def finish
    @store.release
    @late&.kill
    @late&.join
  end

  def ask = { tool_calls: [{ id: "same-id", name: "gated", arguments: {} }] }

  def agent(*turns)
    gated = Mistri::Tool.define("gated", "Needs a person.", needs_approval: true) { @ran += 1 }
    ping = Mistri::Tool.define("ping", "Ping.") { "pong" }
    Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), session: @session,
                      tools: [gated, ping])
  end

  def hold(verb, call_id)
    @store.hold_next_decision
    @late = Thread.new do
      Mistri::Session.new(store: @store, id: "s").public_send(verb, call_id)
    rescue Mistri::ConfigurationError => e
      e
    end

    assert @store.entered.pop(timeout: 5), "the late decision never reached the store"
  end

  # The first call under "same-id" is denied, settled and compacted away
  # while an approval for it is still on its way to the store.
  def deny_and_compact_while_an_approval_is_held
    agent(ask).run("first")
    hold(:approve, "same-id")
    @session.deny("same-id")
    agent({ text: "understood" }).resume
    exchange("later")
    compact
  end

  def land_after(appends)
    count = 0
    @store.release_after { (count += 1) == appends }
  end

  def assert_the_late_decision_lost
    assert @late.join(5), "the late decision never returned"
    assert_kind_of Mistri::ConfigurationError, @late.value
    assert_match(/already been decided/, @late.value.message)
  end
end
