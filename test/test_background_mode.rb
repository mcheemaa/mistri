# frozen_string_literal: true

require_relative "test_helper"

# Background mode: dispatch is a seam, receipts are truthful, lifecycle is
# entries, and a background child's life belongs to the console, not to the
# parent's already-finished turn.
class TestBackgroundMode < Minitest::Test
  def teardown
    Mistri.locks = nil
  end

  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def spawn_call(arguments)
    fake({ tool_calls: [{ name: "spawn_agent", arguments: arguments }] },
         { text: "Parent moved on." })
  end

  def drop_dispatcher
    Class.new do
      attr_reader :spec

      def call(spec, _runner)
        @spec = spec
        nil
      end
    end.new
  end

  def await_status(child, wanted, deadline: 3)
    ends = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
    while child.status != wanted && Process.clock_gettime(Process::CLOCK_MONOTONIC) < ends
      sleep 0.05
    end
    child.status
  end

  def test_workspace_sharing_refuses_background_in_band
    spawn = Mistri::SubAgent.spawner(provider: fake, dispatcher: Mistri::Dispatchers::Inline.new)
    parent = spawn_call({ "name" => "Husky", "task" => "t", "instructions" => "You help.",
                          "mode" => "background", "workspace" => "parent" })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")

    refusal = session.messages.select(&:tool?).last

    assert_match(/must run inline/, refusal.text)
    assert_empty session.children
  end

  def test_inline_dispatcher_finishes_during_the_spawn_and_says_so
    child_fake = fake({ text: "The answer is 7." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake,
                                     dispatcher: Mistri::Dispatchers::Inline.new)
    parent = spawn_call({ "name" => "Corgi", "task" => "answer", "instructions" => "Answer.",
                          "mode" => "background" })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    result = Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")

    assert_equal "Parent moved on.", result.text
    receipt = session.messages.select(&:tool?).last

    assert_match(/already finished \(done\)/, receipt.text)
    assert_equal "background", receipt.ui["mode"]
    child = session.children.first

    assert_equal :done, child.status
    assert_equal "The answer is 7.", child.report
  end

  def test_thread_dispatcher_runs_the_child_while_the_parent_moves_on
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    slow = Mistri::Tool.define("slow", "Takes a while.") do
      sleep 0.6
      "worked"
    end
    child_fake = fake({ tool_calls: [{ name: "slow", arguments: {} }] },
                      { text: "Finished the slow work." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [slow],
                                     dispatcher: Mistri::Dispatchers::Thread.new)
    parent = spawn_call({ "name" => "Whippet", "task" => "work slowly",
                          "instructions" => "Use slow, then report.",
                          "mode" => "background" })
    session = Mistri::Session.new(store:)

    result = Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")

    assert_equal "Parent moved on.", result.text, "the parent never waits"
    child = session.children.first
    receipt = session.messages.select(&:tool?).last

    assert_match(/working in the background/, receipt.text)
    assert_equal :running, child.status, "the child is still at work as the parent finishes"

    assert_equal :done, await_status(child, :done)
    assert_equal "Finished the slow work.", child.report
    refute Mistri.locks.held?(Mistri::Child.lease_key(child.session_id))
  end

  def test_a_dropped_spec_reads_queued_and_run_dispatched_picks_it_up
    dropper = drop_dispatcher
    child_fake = fake({ text: "Ran from the job." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, dispatcher: dropper)
    parent = spawn_call({ "name" => "Basset", "task" => "do the thing",
                          "instructions" => "You do things.", "mode" => "background" })
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)

    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")

    child = session.children.first

    assert_equal :queued, child.status, "dispatched but never started is queued, honestly"

    # The host job reconstructs from the wire-shaped spec and calls back in.
    spec = JSON.parse(JSON.generate(dropper.spec))
    result = Mistri::SubAgent.run_dispatched(spec, provider: child_fake,
                                                   system: spec.fetch("instructions"),
                                                   tools: [], store: store)

    assert_predicate result, :completed?
    assert_equal :done, child.status
    assert_equal "Ran from the job.", child.report
  end

  def test_stopping_a_background_child_needs_no_parent
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    slow = Mistri::Tool.define("slow", "Takes a while.") do
      sleep 1.4
      "worked"
    end
    child_fake = fake({ tool_calls: [{ name: "slow", arguments: {} }] },
                      { text: "never reached" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [slow],
                                     dispatcher: Mistri::Dispatchers::Thread.new)
    parent = spawn_call({ "name" => "Pointer", "task" => "work",
                          "instructions" => "Use slow.", "mode" => "background" })
    session = Mistri::Session.new(store:)

    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")
    child = session.children.first

    assert child.stop, "the console can stop a background child"
    assert_equal :stopped, await_status(child, :stopped)
  end

  def test_mode_and_workspace_only_exist_with_a_dispatcher
    bare = Mistri::SubAgent.spawner(provider: fake)
    dispatched = Mistri::SubAgent.spawner(provider: fake,
                                          dispatcher: Mistri::Dispatchers::Inline.new)

    refute bare.input_schema[:properties].key?("mode")
    assert dispatched.input_schema[:properties].key?("mode")
    assert dispatched.input_schema[:properties].key?("workspace")
  end
end
