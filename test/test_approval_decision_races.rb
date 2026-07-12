# frozen_string_literal: true

require_relative "test_helper"

# Approval decisions are a write-once register over the store's durable order.
class TestApprovalDecisionRaces < Minitest::Test
  class RacingStore
    def initialize
      @store = Mistri::Stores::Memory.new
      @barrier_mutex = Mutex.new
      @barrier_cv = ConditionVariable.new
      @read_barrier = nil
      @gate_mutex = Mutex.new
      @decision_gate = nil
    end

    def append(id, entry)
      gate = gated_decision(entry)
      if gate
        gate.fetch(:waiting) << true
        gate.fetch(:release).pop
      end
      @store.append(id, entry)
    end

    def load(id)
      snapshot = @store.load(id)
      wait_at_read_barrier
      snapshot
    end

    def race_next_loads(count)
      @barrier_mutex.synchronize do
        raise "read barrier is already active" if @read_barrier

        @read_barrier = { remaining: count }
      end
    end

    def pause_next_decision(approved)
      gate = { approved:, waiting: Queue.new, release: Queue.new }
      @gate_mutex.synchronize do
        raise "decision gate is already active" if @decision_gate

        @decision_gate = gate
      end
      gate
    end

    private

    def gated_decision(entry)
      @gate_mutex.synchronize do
        gate = @decision_gate
        return unless gate && entry["type"] == "approval_decision"
        return unless entry["approved"] == gate.fetch(:approved)

        @decision_gate = nil
        gate
      end
    end

    def wait_at_read_barrier
      @barrier_mutex.synchronize do
        barrier = @read_barrier
        return unless barrier

        barrier[:remaining] -= 1
        if barrier[:remaining].zero?
          @read_barrier = nil
          @barrier_cv.broadcast
        else
          @barrier_cv.wait(@barrier_mutex) while @read_barrier.equal?(barrier)
        end
      end
    end
  end

  def test_concurrent_agreement_is_idempotent_and_executes_once
    [true, false].each do |approved|
      store = RacingStore.new
      agent, call, writes = parked_agent(store)
      store.race_next_loads(2)
      action = approved ? :approve : :deny

      outcomes = concurrently(
        -> { fresh_session(agent).public_send(action, call.id, note: "operator a") },
        -> { fresh_session(agent).public_send(action, call.id, note: "operator b") }
      )

      assert_equal(2, outcomes.count { |status, _| status == :ok }, action.to_s)
      decisions = approval_decisions(agent.session)

      assert_equal 2, decisions.length, "both stale writers reached append"
      durable = agent.session.open_approvals.fetch(0).fetch(:decision)

      assert_equal approved, durable["approved"]
      assert_equal decisions.first["note"], durable["note"],
                   "the first note remains authoritative"

      result = agent.resume

      assert_predicate result, :completed?
      assert_equal(approved ? 1 : 0, writes.length)
      assert_empty agent.session.open_approvals
    end
  end

  def test_concurrent_conflict_reports_the_loser_and_follows_durable_order
    assert_conflict_follows(true)
    assert_conflict_follows(false)
  end

  def test_a_stale_conflict_after_execution_cannot_poison_the_session
    store = RacingStore.new
    agent, call, writes = parked_agent(store)
    gate = store.pause_next_decision(false)
    stale = Thread.new { capture { fresh_session(agent).deny(call.id, note: "late") } }
    gate.fetch(:waiting).pop

    approve_and_resume(agent, call, writes)

    gate.fetch(:release) << true
    status, error = stale.value

    assert_equal :error, status
    assert_instance_of Mistri::ConfigurationError, error
    assert_settled_session_is_usable(agent, call)
  ensure
    gate&.fetch(:release)&.push(true) if gate&.fetch(:release)&.empty?
    stale&.join
  end

  def test_a_stale_approval_after_denial_cannot_launder_the_winner
    store = RacingStore.new
    agent, call, writes = parked_agent(store)
    gate = store.pause_next_decision(true)
    stale = Thread.new { capture { fresh_session(agent).approve(call.id, note: "late") } }
    gate.fetch(:waiting).pop

    agent.session.deny(call.id, note: "winner")
    result = agent.resume

    assert_predicate result, :completed?
    assert_empty writes

    gate.fetch(:release) << true
    status, error = stale.value

    assert_equal :error, status
    assert_instance_of Mistri::ConfigurationError, error
    assert_empty agent.session.open_approvals
    tool_result = agent.session.messages.select(&:tool?).fetch(0)

    assert_match(/denied this tool call: winner/, tool_result.text)
  ensure
    gate&.fetch(:release)&.push(true) if gate&.fetch(:release)&.empty?
    stale&.join
  end

  private

  def assert_conflict_follows(winner)
    agent, writes, outcomes, decisions = raced_conflict(winner)

    assert_equal winner, decisions.fetch(0).fetch("approved")
    assert_equal 2, decisions.length
    assert_equal :ok, outcomes.fetch(winner).fetch(0)
    loser = outcomes.fetch(!winner)

    assert_equal :error, loser.fetch(0)
    assert_instance_of Mistri::ConfigurationError, loser.fetch(1)
    assert_match(/already been decided/, loser.fetch(1).message)

    result = agent.resume

    assert_predicate result, :completed?
    assert_equal(winner ? 1 : 0, writes.length)
    assert_empty agent.session.open_approvals
  end

  def approve_and_resume(agent, call, writes)
    agent.session.approve(call.id, note: "winner")
    result = agent.resume

    assert_predicate result, :completed?
    assert_equal 1, writes.length
  end

  def assert_settled_session_is_usable(agent, call)
    assert_empty agent.session.open_approvals
    assert_equal "written", agent.session.messages.select(&:tool?).fetch(0).text
    before_retry = agent.session.entries.length

    assert_nil agent.session.approve(call.id, note: "network retry")
    assert_raises(Mistri::ConfigurationError) { agent.session.deny(call.id) }
    assert_equal before_retry, agent.session.entries.length
    assert_stale_loser_does_not_block_compaction(agent)

    continued = agent.run("Continue after the settled approval.")

    assert_predicate continued, :completed?
  end

  def assert_stale_loser_does_not_block_compaction(agent)
    3.times do |index|
      text = "history #{index} " * 20
      agent.session.append_message(Mistri::Message.user(text))
      agent.session.append_message(Mistri::Message.assistant(content: "acknowledged #{index}"))
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "durable checkpoint" }])
    result = Mistri::Compactor.call(
      session: agent.session, provider:, settings: Mistri::Compaction.new(keep_recent: 10)
    )

    assert_equal "durable checkpoint", result.fetch(:summary)
    assert_equal "durable checkpoint", agent.session.last_compaction.fetch("summary")
  end

  def parked_agent(store)
    writes = []
    tool = Mistri::Tool.define("write", "Writes once.", needs_approval: true) do
      writes << :written
      "written"
    end
    turns = [
      { tool_calls: [{ name: "write", arguments: {} }] },
      { text: "settled" },
      { text: "continued" }
    ]
    provider = Mistri::Providers::Fake.new(turns:)
    session = Mistri::Session.new(store:)
    agent = Mistri::Agent.new(provider:, tools: [tool], session:)
    call = agent.run("go").pending.fetch(0)
    [agent, call, writes]
  end

  def raced_conflict(winner)
    store = RacingStore.new
    agent, call, writes = parked_agent(store)
    store.race_next_loads(2)
    gate = store.pause_next_decision(!winner)
    attempts = {
      true => Thread.new { capture { fresh_session(agent).approve(call.id) } },
      false => Thread.new { capture { fresh_session(agent).deny(call.id) } }
    }
    gate.fetch(:waiting).pop
    wait_until { approval_decisions(agent.session).length == 1 }
    gate.fetch(:release) << true
    outcomes = attempts.transform_values(&:value)
    [agent, writes, outcomes, approval_decisions(agent.session)]
  ensure
    gate&.fetch(:release)&.push(true) if gate&.fetch(:release)&.empty?
    attempts&.each_value(&:join)
  end

  def concurrently(*operations)
    operations.map { |operation| Thread.new { capture(&operation) } }.map(&:value)
  end

  def capture
    [:ok, yield]
  rescue StandardError => e
    [:error, e]
  end

  def fresh_session(agent)
    Mistri::Session.new(store: agent.session.store, id: agent.session.id)
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until yield
      raise "timed out waiting for the durable winner" if Process.clock_gettime(
        Process::CLOCK_MONOTONIC
      ) >= deadline

      Thread.pass
    end
  end

  def approval_decisions(session)
    session.entries.select { |entry| entry["type"] == "approval_decision" }
  end
end
