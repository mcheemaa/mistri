# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/session_stores"
require_relative "support/session_scripts"

# Where a compaction may start and what it carries: it never drops an open
# approval, an unfolded steer or report, or half of a call and its result.
class TestSessionCheckpointWriting < Minitest::Test
  include SessionScripts

  def setup
    @store = SessionStores::Recording.new
    @session = Mistri::Session.new(store: @store, id: "s")
  end

  def test_a_compaction_carries_the_children_it_cuts_away
    link("Magpie", "c1")
    3.times { |n| exchange("turn #{n}") }

    compact

    entry = @session.last_compaction

    assert_equal [{ "name" => "Magpie", "session_id" => "c1" }], entry.dig("carried", "children")
    assert_empty entry.dig("carried", "reported")
    assert_equal %w[Magpie], fresh.children.map(&:name)
  end

  def test_a_cut_steps_back_before_a_steer_that_is_not_folded_in
    2.times { |n| exchange("before #{n}") }
    @session.steer("hold on")
    2.times { |n| exchange("after #{n}") }

    compact
    pending = fresh.pending_inbox.map { |entry| entry.dig("message", "content", 0, "text") }

    assert_equal 2, @session.last_compaction["kept_from"]
    assert_equal ["hold on"], pending
  end

  def test_a_cut_is_not_held_back_once_the_steer_is_folded_in
    2.times { |n| exchange("before #{n}") }
    @session.steer("hold on")
    fold(@session.pending_inbox.first)
    2.times { |n| exchange("after #{n}") }

    compact

    assert_equal 8, @session.last_compaction["kept_from"]
    assert_empty fresh.pending_inbox
  end

  def test_a_decision_for_a_call_older_than_the_window_finds_no_open_approval
    gated = Mistri::Tool.define("gated", "Needs a person.", needs_approval: true) { "ran" }
    turns = [{ tool_calls: [{ name: "gated", arguments: {} }] }, { text: "done" }]
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), session: @session,
                              tools: [gated])
    call_id = agent.run("go").pending.first.id
    @session.approve(call_id)
    agent.resume
    exchange("after")

    assert_nil @session.approve(call_id)
    @session.checkpoint(summary: "Earlier.", kept_from: @store.size("s") - 2)

    error = assert_raises(Mistri::ConfigurationError) { fresh.approve(call_id) }
    assert_match(/no open approval/, error.message)
  end

  def test_a_decision_that_lands_after_its_call_was_compacted_away_is_ignored
    store = SessionStores::HeldDecision.new
    session = Mistri::Session.new(store:, id: "s")
    gated = Mistri::Tool.define("gated", "Needs a person.", needs_approval: true) { "ran" }
    turns = [{ tool_calls: [{ name: "gated", arguments: {} }] }, { text: "done" }, { text: "on" }]
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), session:,
                              tools: [gated])
    call_id = agent.run("go").pending.first.id
    store.hold_next_decision
    late = Thread.new do
      Mistri::Session.new(store:, id: "s").deny(call_id)
    rescue Mistri::ConfigurationError => e
      e
    end

    assert store.entered.pop(timeout: 5), "the late decision never reached the store"
    session.approve(call_id)
    agent.resume
    exchange("later", session)
    compact(session)
    store.release

    assert late.join(5), "the late decision never returned"
    assert_operator session.last_compaction["kept_from"], :>, 3
    assert_empty Mistri::Session.new(store:, id: "s").open_approvals
    assert_predicate agent.run("carry on"), :completed?
  ensure
    store&.release
    late&.kill
    late&.join
  end

  def test_a_checkpoint_is_refused_when_it_would_cut_past_an_open_approval
    gated = Mistri::Tool.define("gated", "Needs a person.", needs_approval: true) { "ran" }
    turns = [{ tool_calls: [{ name: "gated", arguments: {} }] }]
    Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), session: @session,
                      tools: [gated]).run("go")
    size = @store.size("s")

    error = assert_raises(Mistri::ConfigurationError) do
      @session.checkpoint(summary: "Too far.", kept_from: size)
    end

    assert_match(/open approval/, error.message)
    assert_equal size, @store.size("s")
    assert_equal 1, fresh.open_approvals.length
  end

  def test_a_checkpoint_is_refused_when_it_would_cut_past_an_unfolded_steer
    exchange("before")
    @session.steer("hold on")
    exchange("after")

    error = assert_raises(Mistri::ConfigurationError) do
      @session.checkpoint(summary: "Too far.", kept_from: 3)
    end

    assert_match(/not folded in/, error.message)
    assert_equal 1, fresh.pending_inbox.length
  end

  def test_a_checkpoint_is_refused_when_it_would_split_a_call_from_its_result
    call("one")

    error = assert_raises(Mistri::ConfigurationError) do
      @session.checkpoint(summary: "Mid call.", kept_from: 1)
    end

    assert_match(/splits a tool call/, error.message)
  end

  def test_a_checkpoint_cannot_move_the_start_back_or_past_the_end
    3.times { |n| exchange("turn #{n}") }
    @session.checkpoint(summary: "One.", kept_from: 4)

    [2, 8, -1, "4"].each do |kept_from|
      assert_raises(Mistri::ConfigurationError) do
        @session.checkpoint(summary: "Bad.", kept_from:)
      end
    end
    assert_equal 7, @store.size("s")
  end
end
