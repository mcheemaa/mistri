# frozen_string_literal: true

require_relative "test_helper"

# A Child reads its session through a held log, so a wait reads the child's
# log once and then only what was appended since, and still answers what a
# read of the whole log would.
class TestChildLog < Minitest::Test
  # Records each load of one session: where it starts and how many entries
  # it returns.
  class RecordingStore < Mistri::Stores::Memory
    Read = Data.define(:from, :entries)

    def reads(id) = (@reads ||= Hash.new { |hash, key| hash[key] = [] })[id]

    def load(id, from: 0)
      super.tap { |entries| reads(id) << Read.new(from:, entries: entries.length) }
    end
  end

  # A store written before partial reads: append and load(id), nothing else.
  class PlainStore
    def initialize = @store = Mistri::Stores::Memory.new

    def append(id, entry) = @store.append(id, entry)

    def load(id) = @store.load(id)
  end

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
    @store = RecordingStore.new
    @session = Mistri::Session.new(store: @store, id: "child-1")
    @child = Mistri::Child.new(name: "Magpie", session_id: "child-1", store: @store)
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

  def test_a_console_wait_reads_each_entry_of_the_child_once
    30.times { |n| @session.append_message(Mistri::Message.user("step #{n}")) }
    finisher = Thread.new do
      sleep 0.05
      @session.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "Found it.")
    end

    output = Mistri::Console.await(@child, 2, 0.01)
    finisher.join
    read = @store.reads("child-1").sum(&:entries)

    assert_match(/Magpie done\./, output)
    assert_equal @store.load("child-1").length, read
  end

  def test_every_answer_matches_one_read_of_the_whole_log
    script.each do |step|
      step.call

      READS.each do |name, read|
        whole = read.call(Mistri::Child.new(name: "Magpie", session_id: "child-1", store: @store))

        assert_equal [whole], [read.call(@child)], "#{name} differs from the whole log"
      end
    end
  end

  def test_a_report_and_a_transcript_are_values_the_caller_owns
    @session.append_message(Mistri::Message.user("look into it"))
    @session.append(Mistri::Child::TERMINAL, "status" => "failed", "report" => "Half done.",
                                             "error" => "Timeout")

    @child.report << " changed"
    @child.error << " changed"
    @child.transcript.first["message"]["content"].first["text"] << " changed"

    assert_equal "Half done.", @child.report
    assert_equal "Timeout", @child.error
    assert_equal "look into it", @child.transcript.first.dig("message", "content", 0, "text")
  end

  def test_a_child_on_a_store_with_only_append_and_load_still_answers
    store = PlainStore.new
    session = Mistri::Session.new(store:, id: "child-2")
    child = Mistri::Child.new(name: "Husky", session_id: "child-2", store:)
    session.append(Mistri::Child::DISPATCHED, {})

    assert_equal :queued, child.status
    session.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "Done.")

    assert_predicate child, :finished?
    assert_equal "Done.", child.report
  end

  private

  # One child from its queue to its end, with a steer that lands after it.
  def script
    [-> { @session.append(Mistri::Child::DISPATCHED, { "spec" => { "name" => "Magpie" } }) },
     -> { @session.append(Mistri::Child::STARTED, {}) },
     -> { @session.append_message(Mistri::Message.user("find the answer")) },
     -> { @session.append_message(Mistri::Message.assistant(content: "On it.")) },
     -> { @child.say("also check the pricing page") },
     -> { @session.append_message(Mistri::Message.user("also check the pricing page")) },
     -> { @session.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "It is 42.") },
     -> { @child.say("too late") }]
  end
end
