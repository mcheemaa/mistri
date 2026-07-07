# frozen_string_literal: true

require_relative "test_helper"

# The lock adapter: leases that expire unless renewed, flags that carry
# one-bit requests between processes, and the liveness refinement children
# gain when an adapter is configured.
class TestLocks < Minitest::Test
  def teardown
    Mistri.locks = nil
  end

  def test_memory_leases_acquire_once_and_expire
    locks = Mistri::Locks::Memory.new

    assert locks.acquire("run:1", ttl: 60)
    refute locks.acquire("run:1", ttl: 60), "a held lease cannot be taken"
    assert locks.held?("run:1")

    locks.release("run:1")

    refute locks.held?("run:1")
    assert locks.acquire("run:1", ttl: 0.01)
    sleep 0.02

    refute locks.held?("run:1"), "an unrenewed lease expires on its own"
    assert locks.acquire("run:1", ttl: 60), "an expired lease can be retaken"
  end

  def test_flags_set_read_and_clear
    locks = Mistri::Locks::Memory.new

    refute locks.flag?("stop:1")
    locks.set_flag("stop:1")

    assert locks.flag?("stop:1")
    locks.clear_flag("stop:1")

    refute locks.flag?("stop:1")
  end

  def test_hold_renews_on_a_heartbeat_and_releases_cleanly
    Mistri.locks = Mistri::Locks::Memory.new
    hold = Mistri::Locks.hold("child:x", ttl: 0.2, heartbeat: 0.05)

    assert Mistri.locks.held?("child:x")
    sleep 0.3

    assert Mistri.locks.held?("child:x"), "the heartbeat outlives the ttl"

    hold.release

    refute Mistri.locks.held?("child:x"), "release deletes the lease"
    sleep 0.1

    refute Mistri.locks.held?("child:x"), "no tick re-stamps a released lease"
  end

  def test_hold_is_a_no_op_without_an_adapter
    assert_nil Mistri::Locks.hold("child:x")
  end

  def test_renewal_honors_a_fractional_heartbeat_above_the_tick
    renewed_at = []
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    spy = Class.new(Mistri::Locks::Memory) do
      define_method(:renew) do |key, ttl:|
        renewed_at << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        super(key, ttl: ttl)
      end
    end.new
    Mistri.locks = spy
    hold = Mistri::Locks.hold("run:1", ttl: 5, heartbeat: 1.5)

    sleep 1.9
    hold.release

    assert_predicate renewed_at, :any?, "a 1.5s heartbeat must have renewed by 1.9s"
    assert_operator renewed_at.first, :<, 1.75,
                    "renewal follows the requested cadence, not tick rounding"
  end

  def test_hold_respects_an_existing_holder
    Mistri.locks = Mistri::Locks::Memory.new
    first = Mistri::Locks.hold("run:1", ttl: 60, heartbeat: 60)

    assert_nil Mistri::Locks.hold("run:1", ttl: 60, heartbeat: 60),
               "a refused hold must not exist"
    assert Mistri.locks.held?("run:1"), "the real holder keeps its lease"

    first.release

    refute Mistri.locks.held?("run:1")
  end

  def test_a_child_without_lease_or_terminal_reads_interrupted
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    parent = Mistri::Session.new(store:)
    dead = Mistri::Session.new(store:)
    parent.append("subagent", "name" => "Husky", "session_id" => dead.id)

    assert_equal :interrupted, parent.children.first.status

    Mistri.locks.acquire(Mistri::Child.lease_key(dead.id), ttl: 60)

    assert_equal :running, parent.children.first.status
  end

  def test_a_live_child_holds_its_lease_while_running
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    seen = nil
    probe = Mistri::Tool.define("probe", "Checks the lease.") do |_args, context|
      key = Mistri::Child.lease_key(context.session.id)
      seen = Mistri.locks.held?(key)
      "checked"
    end
    child_fake = Mistri::Providers::Fake.new(turns: [
                                               { tool_calls: [{ name: "probe", arguments: {} }] },
                                               { text: "Done." }
                                             ])
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [probe])
    parent_fake = Mistri::Providers::Fake.new(turns: [
                                                { tool_calls: [{ name: "spawn_agent",
                                                                 arguments: {
                                                                   "name" => "Collie",
                                                                   "task" => "probe the lease",
                                                                   "instructions" => "Probe."
                                                                 } }] },
                                                { text: "All done." }
                                              ])
    session = Mistri::Session.new(store:)

    Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:).run("go")

    assert seen, "the lease is held while the child runs"
    child = session.children.first

    assert_equal :done, child.status
    refute Mistri.locks.held?(Mistri::Child.lease_key(child.session_id)),
           "the lease releases when the child ends"
  end

  def test_rails_cache_adapter_speaks_the_same_interface
    begin
      require "active_support"
      require "active_support/cache"
    rescue LoadError
      skip "activesupport not installed"
    end

    require "mistri/locks/rails_cache"
    cache = ActiveSupport::Cache::MemoryStore.new
    locks = Mistri::Locks::RailsCache.new(cache: cache)

    assert locks.acquire("run:1", ttl: 60)
    refute locks.acquire("run:1", ttl: 60)
    assert locks.held?("run:1")
    locks.set_flag("stop:1")

    assert locks.flag?("stop:1")
    locks.release("run:1")
    locks.clear_flag("stop:1")

    refute locks.held?("run:1")
    refute locks.flag?("stop:1")
  end
end
