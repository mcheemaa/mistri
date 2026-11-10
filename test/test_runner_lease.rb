# frozen_string_literal: true

require_relative "test_helper"
require "logger"
require "stringio"

# One active runner per session when a lock adapter is set.
class TestRunnerLease < Minitest::Test
  class FailingRelease < Mistri::Locks::Memory
    def release(key)
      raise "lock backend down" if key.start_with?("child:")

      super
    end
  end

  class FailingAcquire < Mistri::Locks::Memory
    def acquire(*) = raise("lock backend down")
  end

  def setup
    Mistri.locks = Mistri::Locks::Memory.new
  end

  def teardown
    Mistri.locks = nil
    Mistri.logger = nil
  end

  def test_a_second_runner_is_refused_before_it_appends
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    intruder = Mistri::Agent.new(provider: Mistri::Providers::Fake.new, session:)
    refused = []
    appended = nil
    intrude = Mistri::Tool.define("intrude", "Runs the same session again.") do
      before = session.entries.length
      refused << assert_raises(Mistri::SessionBusyError) { intruder.run("hi") }
      refused << assert_raises(Mistri::SessionBusyError) { intruder.resume }
      refused << assert_raises(Mistri::SessionBusyError) { intruder.compact }
      appended = session.entries.length - before
      "done"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "intrude", arguments: {} }] },
                                             { text: "ok" }
                                           ])

    Mistri::Agent.new(provider:, session:, tools: [intrude]).run("go")

    assert_equal 3, refused.length
    assert_equal 0, appended
  end

  def test_a_second_call_on_the_leased_agent_is_refused
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    provider = Mistri::Providers::Fake.new(turns: [{ text: "first" }, { text: "second" }])
    agent = Mistri::Agent.new(provider:, session:)
    refused = nil
    appended = nil

    # Same thread and fiber as the run.
    agent.run("go") do |event|
      next unless refused.nil? && event.type == :text_delta

      before = session.entries.length
      refused = begin
        agent.run("again")
      rescue Mistri::SessionBusyError => e
        e
      end
      appended = session.entries.length - before
    end

    assert_instance_of Mistri::SessionBusyError, refused
    assert_equal 0, appended
  end

  def test_a_refused_run_writes_nothing_to_the_run_log
    log = StringIO.new
    Mistri.logger = Logger.new(log)
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new)
    hold(agent.session)

    assert_raises(Mistri::SessionBusyError) { agent.run("hi") }
    assert_empty log.string
  end

  def test_the_lease_is_released_when_a_run_raises
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new)

    2.times { assert_raises(Mistri::ConfigurationError) { agent.run("hi") } }
  end

  def test_a_failed_release_warns_and_keeps_the_result
    Mistri.locks = FailingRelease.new
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns: [{ text: "one" }]))
    result = nil

    assert_output(nil, /releasing the lease .* failed/) { result = agent.run("hi") }
    assert_predicate result, :completed?
  end

  def test_a_failed_release_leaves_the_runs_own_error_intact
    Mistri.locks = FailingRelease.new
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new)

    assert_output(nil, /releasing the lease/) do
      assert_raises(Mistri::ConfigurationError) { agent.run("hi") }
    end
  end

  def test_a_task_holds_the_lease_through_its_fix_pass
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: '{"city":"Lahore"}' },
                                             { text: '{"city":"Lahore","temperature":31}' }
                                           ])
    schema = { type: "object",
               properties: { "city" => { type: "string" }, "temperature" => { type: "number" } },
               required: %w[city temperature] }
    agent = Mistri::Agent.new(provider:)
    held = []

    result = agent.task("weather", schema:) do |event|
      held << Mistri.locks.held?(Mistri::Child.lease_key(agent.session.id)) if event.type == :start
    end

    assert_equal 31, result.output["temperature"]
    assert_equal [true, true], held
  end

  def test_an_agent_built_without_a_lease_takes_none
    provider = Mistri::Providers::Fake.new(turns: [{ text: "one" }])
    agent = Mistri::Agent.new(provider:, lease: false)
    held = nil

    agent.run("hi") { held ||= Mistri.locks.held?(Mistri::Child.lease_key(agent.session.id)) }

    refute held
  end

  def test_a_refused_run_leaves_queued_steers_pending
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new)
    agent.session.steer("queued")
    hold(agent.session)

    assert_raises(Mistri::SessionBusyError) { agent.run("hi") }
    assert_equal 1, agent.session.pending_inbox.length
  end

  def test_a_refused_resume_leaves_approved_calls_unrun
    runs = 0
    gated = Mistri::Tool.define("gated", "Needs a human.", needs_approval: true) { runs += 1 }
    turn = { tool_calls: [{ name: "gated", arguments: {} }] }
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns: [turn]), tools: [gated])
    agent.session.approve(agent.run("go").pending.first.id)
    hold(agent.session)

    assert_raises(Mistri::SessionBusyError) { agent.resume }
    assert_equal 0, runs
  end

  def test_a_lock_backend_that_is_down_does_not_stop_a_run
    Mistri.locks = FailingAcquire.new
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns: [{ text: "hi" }]))
    result = nil

    assert_output(nil, /lock backend failed .* runs without its lease/) { result = agent.run("hi") }
    assert_predicate result, :completed?
  end

  private

  def hold(session)
    Mistri.locks.acquire(Mistri::Child.lease_key(session.id), ttl: 60)
  end
end
