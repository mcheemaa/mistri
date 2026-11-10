# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/session_stores"

# A Child reads through a held log and still answers what a whole read would.
class TestChildLog < Minitest::Test
  TERMINAL = Mistri::Child::TERMINAL
  DISPATCHED = Mistri::Child::DISPATCHED
  STARTED = Mistri::Child::STARTED

  READS = {
    status: lambda(&:status),
    finished: lambda(&:finished?),
    report: lambda(&:report),
    error: lambda(&:error),
    tail: ->(child) { child.transcript(tail: 3) },
    transcript: ->(child) { child.transcript(tail: nil) },
    to_h: lambda(&:to_h)
  }.freeze

  def setup
    @store = SessionStores::Recording.new
    @session = Mistri::Session.new(store: @store, id: "child-1")
    @child = window(@store)
  end

  def teardown
    Mistri.locks = nil
  end

  def test_a_wait_reads_the_childs_log_once_and_then_only_what_is_new
    20.times { |n| @session.append_message(Mistri::Message.user("step #{n}")) }
    @child.finished?
    @child.status
    @session.append_message(Mistri::Message.user("one more"))
    @child.finished?
    @child.status

    assert_equal [0, 20, 20, 21], @store.reads("child-1").map(&:from)
    assert_equal [20, 0, 1, 0], @store.reads("child-1").map(&:entries)
  end

  def test_a_console_wait_polls_before_the_end_and_reads_each_entry_once
    30.times { |n| @session.append_message(Mistri::Message.user("step #{n}")) }
    waiter = Thread.new { Mistri::Console.await(@child, 5, 0.01) }
    wait_for_loads(2)
    @session.append(TERMINAL, "status" => "done", "report" => "Found it.")

    assert waiter.join(5), "the wait never returned"
    reads = @store.reads("child-1")

    assert_match(/Magpie done\./, waiter.value)
    assert_equal [30, 0], reads.first(2).map(&:entries)
    assert_equal 31, reads.sum(&:entries)
  ensure
    waiter&.kill
    waiter&.join
  end

  def test_every_answer_matches_one_read_of_the_whole_log
    script.each do |step|
      step.call

      READS.each do |name, read|
        assert_equal [read.call(window(@store))], [read.call(@child)],
                     "#{name} differs from the whole log"
      end
    end
  end

  def test_a_report_and_a_transcript_are_values_the_caller_owns
    @session.append_message(Mistri::Message.user("look into it"))
    @session.append(TERMINAL, "status" => "failed", "report" => "Half done.", "error" => "Timeout")

    @child.report << " changed"
    @child.error << " changed"
    @child.transcript.first["message"]["content"].first["text"] << " changed"

    assert_equal "Half done.", @child.report
    assert_equal "Timeout", @child.error
    assert_equal "look into it", @child.transcript.first.dig("message", "content", 0, "text")
  end

  def test_a_child_on_a_store_with_only_append_and_load_still_answers
    store = SessionStores::Plain.new
    session = Mistri::Session.new(store:, id: "child-1")
    child = window(store)
    session.append(DISPATCHED, {})

    assert_equal :queued, child.status
    session.append(TERMINAL, "status" => "done", "report" => "Done.")

    assert_predicate child, :finished?
    assert_equal "Done.", child.report
  end

  def test_an_end_that_is_rolled_back_is_not_kept
    store = SessionStores::Transactional.new
    session = Mistri::Session.new(store:, id: "child-1")
    child = window(store)
    session.append(DISPATCHED, {})
    child.status

    store.transaction do
      session.append(TERMINAL, "status" => "done", "report" => "Never committed.")

      assert_predicate child, :finished?
      raise SessionStores::Transactional::Rollback
    end

    refute_predicate child, :finished?
    assert_equal :queued, child.status
    assert_nil child.report
  end

  def test_a_read_inside_an_older_snapshot_does_not_see_a_later_end
    store = SessionStores::Snapshot.new
    session = Mistri::Session.new(store:, id: "child-1")
    child = window(store)
    session.append(DISPATCHED, {})
    store.pin
    Thread.new do
      session.append(TERMINAL, "status" => "done", "report" => "Later.")
      child.finished?
    end.join

    refute_predicate child, :finished?
    assert_equal :queued, child.status
    store.unpin

    assert_equal "Later.", child.report
  ensure
    store&.unpin
  end

  def test_two_threads_on_one_window_read_each_entry_once
    store = SessionStores::Gated.new
    session = Mistri::Session.new(store:, id: "child-1")
    child = window(store)
    session.append(DISPATCHED, {})
    session.append(TERMINAL, "status" => "done", "report" => "Done.")
    store.hold_next_load
    first = Thread.new { child.status }

    assert store.entered.pop(timeout: 5), "the first reader never reached the store"
    second = Thread.new { child.report }
    wait_until { second.status == "sleep" }
    store.release

    assert first.join(5) && second.join(5), "a reader never returned"
    assert_equal [:done, "Done."], [first.value, second.value]
    assert_equal [0, 2], store.starts
  ensure
    store&.release
    [first, second].compact.each(&:kill).each(&:join)
  end

  def test_a_stop_through_a_warmed_window_ends_a_queued_child_once
    Mistri.locks = Mistri::Locks::Memory.new
    @session.append(DISPATCHED, {})
    @child.status

    assert @child.stop
    assert @child.stop

    assert_equal :stopped, @child.status
    assert_equal ["stopped"], ends
  end

  def test_a_stop_through_a_warmed_window_sees_an_end_another_writer_appended
    Mistri.locks = Mistri::Locks::Memory.new
    @session.append(DISPATCHED, {})
    @child.status
    @session.append(TERMINAL, "status" => "done", "report" => "Finished first.")

    assert @child.stop

    assert_equal :done, @child.status
    assert_equal ["done"], ends
  end

  def test_a_wait_and_a_stop_share_one_window
    Mistri.locks = Mistri::Locks::Memory.new
    @session.append(DISPATCHED, {})
    waiter = Thread.new { Mistri::Console.await(@child, 5, 0.01) }
    wait_for_loads(2)

    assert @child.stop
    assert waiter.join(5), "the wait never returned"

    assert_match(/Magpie stopped\./, waiter.value)
    assert_equal ["stopped"], ends
  ensure
    waiter&.kill
    waiter&.join
  end

  def test_changing_the_string_a_child_was_given_does_not_move_the_window
    Mistri.locks = Mistri::Locks::Memory.new
    Mistri::Session.new(store: @store, id: "child-2").append(DISPATCHED, {})
    @session.append(DISPATCHED, {})
    @session.append(TERMINAL, "status" => "done", "report" => "From the first.")
    id = +"child-1"
    child = Mistri::Child.new(name: "Magpie", session_id: id, store: @store)
    child.report

    id.replace("child-2")

    assert_equal "child-1", child.session_id
    assert_equal "From the first.", child.report
    assert child.stop
    assert_equal ["done"], ends
    assert_equal :queued, window(@store, "child-2").status
  end

  def test_a_changed_id_string_does_not_move_a_stop_a_steer_or_the_report
    Mistri.locks = Mistri::Locks::Memory.new
    @session.append(DISPATCHED, "spec" => dispatch_spec)
    id = +"child-1"
    child = Mistri::Child.new(name: "Magpie", session_id: id, store: @store)
    child.status
    id.replace("child-2")
    child.session_id << " changed"
    Mistri.locks.acquire(Mistri::Child.lease_key("child-1"), ttl: 30)

    assert child.stop
    assert Mistri.locks.flag?(Mistri::Child.stop_key("child-1"))
    refute Mistri.locks.flag?(Mistri::Child.stop_key("child-2"))
    child.say("wrap up")
    Mistri.locks.release(Mistri::Child.lease_key("child-1"))

    2.times { assert child.stop }

    steers = @store.load("child-1").count { |entry| entry["type"] == "steer" }

    assert_equal ["stopped"], ends
    assert_equal 1, steers
    assert_empty @store.load("child-2")
    assert_equal [%w[Magpie child-1 stopped]], reports_to("parent-1")
  end

  def test_the_session_id_a_child_returns_is_a_copy_the_caller_owns
    Mistri.locks = Mistri::Locks::Memory.new
    @session.append(DISPATCHED, {})
    child = Mistri::Child.new(name: "Magpie", session_id: +"child-1", store: @store)

    child.session_id << " changed"
    child.to_h["session_id"] << " changed"

    assert_equal "child-1", child.session_id
    assert child.stop
    assert_equal ["stopped"], ends
  end

  private

  def window(store, session_id = "child-1")
    Mistri::Child.new(name: "Magpie", session_id:, store:)
  end

  def ends
    @store.load("child-1").filter_map { |entry| entry["status"] if entry["type"] == TERMINAL }
  end

  def dispatch_spec
    { "spec_version" => Mistri::SubAgent::DISPATCH_SPEC_VERSION, "session_id" => "child-1",
      "parent_session_id" => "parent-1", "name" => "Magpie" }
  end

  def reports_to(parent_id)
    @store.load(parent_id).filter_map do |entry|
      entry.values_at("name", "session_id", "status") if entry["type"] == "subagent_report"
    end
  end

  def wait_for_loads(count)
    count.times { flunk "the wait never polled" unless @store.loaded.pop(timeout: 5) }
  end

  # One child from its queue to a second end written after the first.
  def script
    [-> { @session.append(DISPATCHED, { "spec" => { "name" => "Magpie" } }) },
     -> { @session.append(STARTED, {}) },
     -> { @session.append_message(Mistri::Message.user("find the answer")) },
     -> { @session.append_message(Mistri::Message.assistant(content: "On it.")) },
     -> { @child.say("also check the pricing page") },
     -> { @session.append_message(Mistri::Message.user("also check the pricing page")) },
     -> { @session.append(TERMINAL, "status" => "done", "report" => "It is 42.") },
     -> { @child.say("too late") },
     -> { @session.append(TERMINAL, "status" => "failed", "error" => "Ended a second time.") }]
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until yield
      late = Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      flunk "the condition was not met in time" if late

      Thread.pass
    end
  end
end
