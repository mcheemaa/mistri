# frozen_string_literal: true

require_relative "test_helper"

# Stopping one child: the parent's abort cascades down, a child's stop stays
# its own, a cross-process stop flag becomes the child's cooperative abort
# within a tick, and every stopped child ends with a stopped terminal while
# the parent runs on.
class TestChildStop < Minitest::Test
  def teardown
    Mistri.locks = nil
  end

  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def blocking_link_store
    Class.new do
      attr_reader :entered, :continue

      def initialize
        @store = Mistri::Stores::Memory.new
        @entered = Queue.new
        @continue = Queue.new
        @block = true
      end

      def append(id, entry)
        @store.append(id, entry)
        return unless @block && entry["type"] == "subagent"

        @block = false
        @entered << true
        @continue.pop
      end

      def load(id) = @store.load(id)
    end.new
  end

  def test_derive_cascades_down_and_never_up
    parent = Mistri::AbortSignal.new
    child, _handle = parent.derive

    refute_predicate child, :aborted?
    parent.abort!(:closing)

    assert_predicate child, :aborted?, "the parent's abort reaches the child"
    assert_equal :closing, child.reason

    other_parent = Mistri::AbortSignal.new
    other_child, = other_parent.derive
    other_child.abort!(:done_early)

    refute_predicate other_parent, :aborted?, "a child's abort never climbs"
  end

  def test_a_removed_handle_stops_the_cascade
    parent = Mistri::AbortSignal.new
    child, handle = parent.derive
    parent.remove_callback(handle)

    parent.abort!(:late)

    refute_predicate child, :aborted?, "a finished child must not hear later aborts"
  end

  def test_a_run_stopped_during_tools_reports_aborted
    signal = Mistri::AbortSignal.new
    stop_here = Mistri::Tool.define("stop_here", "Trips the abort.") do
      signal.abort!(:user_stop)
      "stopped"
    end
    provider = fake({ tool_calls: [{ name: "stop_here", arguments: {} }] })
    result = Mistri::Agent.new(provider:, tools: [stop_here]).run("go", signal:)

    assert_predicate result, :aborted?, "the signal knows the user stopped it, not the message"
  end

  def test_stopping_a_child_leaves_the_parent_running
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    linger = Mistri::Tool.define("linger", "Waits long enough to be stopped.") do |_a, context|
      # Another process asks the child to stop; the lease thread's next tick
      # turns the flag into this run's abort.
      Mistri::Session.new(store:, id: context.session.id)
                     .then { |s| Mistri::Child.new(name: "x", session_id: s.id, store:).stop }
      sleep 1.3
      "lingered"
    end
    child_fake = fake({ tool_calls: [{ name: "linger", arguments: {} }] },
                      { text: "never reached" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [linger])
    parent_fake = fake({ tool_calls: [{ name: "spawn_agent",
                                        arguments: { "name" => "Husky", "task" => "linger",
                                                     "instructions" => "Linger." } }] },
                       { text: "Carried on without Husky." })
    session = Mistri::Session.new(store:)

    result = Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:).run("go")

    assert_equal "Carried on without Husky.", result.text, "the parent finishes its own run"
    child = session.children.first

    assert_equal :stopped, child.status
    tool_message = session.messages.select(&:tool?).last

    assert_match(/was stopped/, tool_message.text)
    assert_predicate tool_message, :tool_error?
    assert_empty session.pending_inbox, "an inline stop must not invent a background report"
    refute Mistri.locks.flag?(Mistri::Child.stop_key(child.session_id)),
           "the stop flag clears when the child ends"
  end

  def test_stopping_an_inline_child_before_its_lease_prevents_execution
    Mistri.locks = Mistri::Locks::Memory.new
    store = blocking_link_store
    child_provider = fake({ text: "must not run" })
    worker = Mistri::SubAgent.new(name: "worker", description: "Works.",
                                  provider: child_provider)
    parent_provider = fake(
      { tool_calls: [{ name: "worker", arguments: { "task" => "work" } }] },
      { text: "Parent continued." }
    )
    session = Mistri::Session.new(store: store)
    result = nil
    runner = Thread.new do
      result = Mistri::Agent.new(provider: parent_provider, tools: [worker.tool],
                                 session: session).run("go")
    end
    store.entered.pop
    child = session.children.first

    assert_equal :interrupted, child.status
    assert child.stop
    store.continue << true
    runner.join

    assert_predicate result, :completed?
    assert_empty child_provider.requests
    assert_equal :stopped, child.status
    terminals = Mistri::Session.new(store: store, id: child.session_id).entries
                               .select { |entry| entry["type"] == Mistri::Child::TERMINAL }

    assert_equal 1, terminals.length
    assert_empty session.pending_inbox
  end

  def test_inline_lease_setup_failure_still_writes_a_failed_terminal
    broken = Class.new do
      def held?(_key) = false
      def acquire(*) = raise("lock backend down")
      def clear_flag(_key) = nil
    end.new
    Mistri.locks = broken
    store = Mistri::Stores::Memory.new
    child_provider = fake({ text: "must not run" })
    worker = Mistri::SubAgent.new(name: "worker", description: "Works.",
                                  provider: child_provider)
    parent_provider = fake(
      { tool_calls: [{ name: "worker", arguments: { "task" => "work" } }] },
      { text: "Parent recovered." }
    )
    session = Mistri::Session.new(store: store)

    result = Mistri::Agent.new(provider: parent_provider, tools: [worker.tool],
                               session: session).run("go")

    assert_predicate result, :completed?
    assert_empty child_provider.requests
    child = session.children.first

    assert_equal :failed, child.status
    assert_match(/lock backend down/, child.error)
    terminals = Mistri::Session.new(store: store, id: child.session_id).entries
                               .select { |entry| entry["type"] == Mistri::Child::TERMINAL }

    assert_equal 1, terminals.length
  end

  def test_inline_lease_cleanup_failure_still_writes_a_failed_terminal
    broken = Class.new(Mistri::Locks::Memory) do
      def release(key)
        raise "lock release failed" if key.start_with?("child:")

        super
      end
    end.new
    Mistri.locks = broken
    store = Mistri::Stores::Memory.new
    child_provider = fake({ text: "Child answered." })
    worker = Mistri::SubAgent.new(name: "worker", description: "Works.",
                                  provider: child_provider)
    parent_provider = fake(
      { tool_calls: [{ name: "worker", arguments: { "task" => "work" } }] },
      { text: "Parent recovered." }
    )
    session = Mistri::Session.new(store: store)

    result = Mistri::Agent.new(provider: parent_provider, tools: [worker.tool],
                               session: session).run("go")

    assert_predicate result, :completed?
    assert_equal 1, child_provider.requests.length
    child = session.children.first

    assert_equal :failed, child.status
    assert_match(/lock release failed/, child.error)
    terminals = Mistri::Session.new(store: store, id: child.session_id).entries
                               .select { |entry| entry["type"] == Mistri::Child::TERMINAL }

    assert_equal 1, terminals.length
  end

  def test_stopping_the_parent_stops_a_running_child_through_the_cascade
    store = Mistri::Stores::Memory.new
    parent_signal = Mistri::AbortSignal.new
    pull_plug = Mistri::Tool.define("pull_plug", "Stops the whole run.") do
      parent_signal.abort!(:user_stop)
      "plugged"
    end
    child_fake = fake({ tool_calls: [{ name: "pull_plug", arguments: {} }] },
                      { text: "never reached" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [pull_plug])
    parent_fake = fake({ tool_calls: [{ name: "spawn_agent",
                                        arguments: { "name" => "Corgi", "task" => "go",
                                                     "instructions" => "Go." } }] })
    session = Mistri::Session.new(store:)

    result = Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:)
                          .run("go", signal: parent_signal)

    assert_predicate result, :aborted?, "the parent's own run reports the stop"
    assert_equal :stopped, session.children.first.status,
                 "the cascade reaches the running child"
  end
end
