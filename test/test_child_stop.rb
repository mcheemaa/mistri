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
    refute Mistri.locks.flag?(Mistri::Child.stop_key(child.session_id)),
           "the stop flag clears when the child ends"
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
