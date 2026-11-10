# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/session_stores"

# A finished worker is asked for the end of its log, not the whole of it, so
# a parent with many finished workers does not load their logs to count the
# live ones or to list them.
class TestChildEndReads < Minitest::Test
  def setup
    @store = SessionStores::Recording.new
    @parent = Mistri::Session.new(store: @store, id: "parent")
  end

  def test_a_finished_workers_status_and_report_each_read_its_last_entry
    worker("c1", steps: 40)
    child = window("c1")

    assert_equal :done, child.status
    assert_equal "Done by c1.", child.report
    assert_equal [[40, 1], [40, 1]], reads("c1")
  end

  def test_counting_the_live_workers_reads_one_entry_of_each_finished_one
    5.times { |n| worker("c#{n}", steps: 30) }
    @parent.children
    @store.reads.clear

    live = @parent.children.count { |child| Mistri::Child::LIVE.include?(child.status) }

    assert_equal 0, live
    assert_equal 5, worker_reads.sum(&:entries)
  end

  def test_listing_the_workers_reads_one_entry_of_each_finished_one
    3.times { |n| worker("c#{n}", steps: 30) }
    context = Mistri::ToolContext.new(session: @parent, signal: nil, emit: nil, app: nil)
    @store.reads.clear

    listing = Mistri::Console.list_agents.call({}, context)

    assert_equal 3, listing.scan(": done").length
    assert_equal 3, worker_reads.sum(&:entries)
  end

  def test_a_tail_of_the_transcript_reads_only_those_entries
    worker("c1", steps: 40)
    whole = window("c1").transcript(tail: nil)
    @store.reads.clear

    tail = window("c1").transcript(tail: 5)

    assert_equal whole.last(5), tail
    assert_equal [[36, 5]], reads("c1")
  end

  def test_an_entry_after_the_end_is_found_by_reading_the_whole_log
    worker("c1", steps: 3)
    window("c1").say("too late")
    @store.reads.clear
    child = window("c1")

    assert_equal :done, child.status
    assert_equal "Done by c1.", child.report
    assert_equal [[4, 1], [0, 5], [5, 0]], reads("c1")
  end

  def test_a_worker_that_has_not_finished_is_read_whole_once
    session = Mistri::Session.new(store: @store, id: "c1")
    session.append(Mistri::Child::DISPATCHED, {})
    session.append(Mistri::Child::STARTED, {})
    10.times { |n| session.append_message(Mistri::Message.user("step #{n}")) }
    child = window("c1")

    assert_equal :running, child.status
    refute_predicate child, :finished?
    assert_equal [[11, 1], [0, 12], [12, 0]], reads("c1")
  end

  def test_a_worker_with_no_entries_is_not_finished
    child = window("nobody")

    refute_predicate child, :finished?
    assert_nil child.report
    assert_empty child.transcript(tail: 5)
  end

  private

  def worker(id, steps:)
    @parent.append("subagent", "name" => id, "session_id" => id)
    session = Mistri::Session.new(store: @store, id:)
    steps.times { |n| session.append_message(Mistri::Message.user("step #{n}")) }
    session.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "Done by #{id}.")
  end

  def window(id) = Mistri::Child.new(name: id, session_id: id, store: @store)

  def reads(id) = @store.reads(id).map { |read| [read.from, read.entries] }

  def worker_reads = @store.reads.reject { |read| read.id == "parent" }
end
