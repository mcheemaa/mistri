# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/session_stores"
require_relative "support/session_scripts"

# A session starts at its newest checkpoint: the loop reads and derives from
# there, and the checkpoint carries what it needs from before.
class TestSessionCheckpoint < Minitest::Test
  include SessionScripts

  def setup
    @store = SessionStores::Recording.new
    @session = Mistri::Session.new(store: @store, id: "s")
  end

  def test_a_new_session_reads_one_chunk_from_the_end_of_an_old_log
    200.times { |n| exchange("old #{n}") }
    @session.checkpoint(summary: "Earlier.", kept_from: 396)
    3.times { |n| exchange("new #{n}") }
    @store.reads.clear

    texts = fresh.messages.map(&:text)

    assert_equal([[343, 64]], @store.reads.map { |read| [read.from, read.entries] })
    assert_equal 11, texts.length
    assert_match(/Earlier\./, texts.first)
    assert_equal ["old 198", "OLD 198", "old 199", "OLD 199", "new 0"], texts[1, 5]
  end

  def test_a_window_longer_than_one_chunk_is_read_in_growing_chunks
    10.times { |n| exchange("old #{n}") }
    @session.checkpoint(summary: "Earlier.", kept_from: 20)
    150.times { |n| exchange("new #{n}") }
    @store.reads.clear

    texts = fresh.messages.map(&:text)

    assert_equal([[257, 64], [129, 128], [0, 129]], @store.reads.map { |r| [r.from, r.entries] })
    assert_equal 301, texts.length
    assert_equal "NEW 149", texts.last
  end

  def test_a_checkpoint_that_kept_more_than_the_chunk_holds_is_read_from_its_kept_from
    100.times { |n| exchange("old #{n}") }
    @session.checkpoint(summary: "Earlier.", kept_from: 100)
    @store.reads.clear

    texts = fresh.messages.map(&:text)

    assert_equal([[137, 64], [100, 37]], @store.reads.map { |read| [read.from, read.entries] })
    assert_equal 101, texts.length
    assert_equal "old 50", texts[1]
  end

  def test_a_held_window_moves_forward_when_a_newer_checkpoint_lands
    5.times { |n| exchange("first #{n}") }
    reader = fresh
    reader.messages
    @session.checkpoint(summary: "One.", kept_from: 8)
    exchange("second")
    @session.checkpoint(summary: "Two.", kept_from: 11)
    exchange("third")

    assert_equal fresh.messages.map(&:text), reader.messages.map(&:text)
    assert_equal %w[second SECOND third THIRD], reader.messages.map(&:text).drop(1)
    assert_equal 11, Mistri::Session::Log.new(@store, "s", checkpointed: true).window.offset
  end

  def test_a_compaction_that_carries_nothing_does_not_bound_a_read
    5.times { |n| exchange("old #{n}") }
    @session.append("compaction", "summary" => "By hand.", "kept_from" => 8)
    exchange("new")

    window = Mistri::Session::Log.new(@store, "s", checkpointed: true).window

    assert_equal [0, 13], [window.offset, window.entries.length]
    assert_equal ["old 4", "OLD 4", "new", "NEW"], fresh.messages.map(&:text).drop(1)
  end

  def test_children_stay_complete_across_checkpoints
    link("Magpie", "c1")
    exchange("one")
    @session.checkpoint(summary: "One.", kept_from: 3)
    link("Husky", "c2")
    exchange("two")
    @session.checkpoint(summary: "Two.", kept_from: 7)
    link("Corgi", "c3")

    assert_equal %w[Magpie Husky Corgi], fresh.children.map(&:name)
    assert_equal %w[c1 c2 c3], fresh.children.map(&:session_id)
    assert_equal %w[c1 c2 c3], @session.children.map(&:session_id)
  end

  def test_a_report_delivered_before_a_checkpoint_is_not_delivered_again
    link("Magpie", "c1")
    report = { name: "Magpie", session_id: "c1", status: "done", text: "Found it." }

    assert @session.deliver_report(**report)
    fold(@session.pending_inbox.first)
    exchange("after")
    @session.checkpoint(summary: "One.", kept_from: 5)
    exchange("later")
    @session.checkpoint(summary: "Two.", kept_from: 8)
    before = @store.size("s")

    refute fresh.deliver_report(**report)
    refute @session.deliver_report(**report)
    assert_equal before, @store.size("s")
  end

  def test_a_tool_call_id_from_before_the_window_may_be_used_again
    call("same")
    exchange("between")
    @session.checkpoint(summary: "Earlier.", kept_from: 2)
    call("same")

    assert_equal %w[same], fresh.tool_call_ids.to_a
    assert_equal 5, fresh.messages.length
  end

  def test_an_entry_older_than_the_window_is_not_audited
    @store.append("s", { "type" => "message", "message" => { "role" => "nobody" } })
    exchange("after")
    @store.append("s", { "type" => "compaction", "summary" => "Earlier.", "kept_from" => 1,
                         "carried" => {} })

    assert_empty fresh.open_approvals
    assert_equal %w[after AFTER], fresh.messages.map(&:text).drop(1)
  end

  def test_a_checkpoint_that_is_rolled_back_does_not_move_the_window
    store = SessionStores::Transactional.new
    session = Mistri::Session.new(store:, id: "s")
    3.times { |n| exchange("kept #{n}", session) }
    session.messages

    store.transaction do
      session.checkpoint(summary: "Never committed.", kept_from: 4)

      assert_equal 3, session.messages.length
      raise SessionStores::Transactional::Rollback
    end

    assert_equal 6, session.messages.length
  end

  def test_a_compaction_appended_by_hand_after_a_checkpoint_is_replayed_from_its_own_start
    3.times { |n| exchange("turn #{n}") }
    reader = fresh
    @session.checkpoint(summary: "One.", kept_from: 4)
    reader.messages
    @session.append("compaction", "summary" => "By hand.", "kept_from" => 2)

    expected = ["turn 1", "TURN 1", "turn 2", "TURN 2"]

    assert_equal expected, fresh.messages.map(&:text).drop(1)
    assert_equal expected, reader.messages.map(&:text).drop(1)
  end

  def test_a_checkpoint_entry_with_a_start_beyond_itself_does_not_bound_a_read
    3.times { |n| exchange("turn #{n}") }
    @store.append("s", { "type" => "compaction", "summary" => "Forged.", "kept_from" => 99,
                         "carried" => {} })

    window = Mistri::Session::Log.new(@store, "s", checkpointed: true).window

    assert_equal [0, 7], [window.offset, window.entries.length]
  end

  def test_a_rolled_back_checkpoint_does_not_move_a_window_that_had_already_moved
    store = SessionStores::Transactional.new
    session = Mistri::Session.new(store:, id: "s")
    3.times { |n| exchange("turn #{n}", session) }
    session.checkpoint(summary: "One.", kept_from: 4)
    exchange("more", session)
    before = session.messages.map(&:text)

    store.transaction do
      session.checkpoint(summary: "Never committed.", kept_from: 7)

      assert_equal %w[more MORE], session.messages.map(&:text).drop(1)
      raise SessionStores::Transactional::Rollback
    end

    assert_equal before, session.messages.map(&:text)
    assert_equal 4, session.last_compaction["kept_from"]
  end

  def test_a_read_inside_an_older_snapshot_keeps_the_window_it_had_then
    store = SessionStores::Snapshot.new
    session = Mistri::Session.new(store:, id: "s")
    3.times { |n| exchange("turn #{n}", session) }
    session.checkpoint(summary: "One.", kept_from: 4)
    then_texts = session.messages.map(&:text)
    store.pin
    Thread.new do
      exchange("more", session)
      session.checkpoint(summary: "Two.", kept_from: 7)
      session.messages
    end.join

    assert_equal then_texts, session.messages.map(&:text)
    store.unpin

    assert_equal %w[more MORE], session.messages.map(&:text).drop(1)
  ensure
    store&.unpin
  end

  def test_a_store_without_size_is_read_whole_and_answers_the_same
    plain = SessionStores::Plain.new
    [Mistri::Session.new(store: plain, id: "s"), @session].each do |session|
      link("Magpie", "c1", session)
      20.times { |n| exchange("old #{n}", session) }
      session.steer("pending")
      session.checkpoint(summary: "Earlier.", kept_from: 39)
      exchange("new", session)
    end
    whole = Mistri::Session.new(store: plain, id: "s")
    loads = plain.loads

    assert_equal fresh.messages.map(&:to_h), whole.messages.map(&:to_h)
    assert_equal loads + 1, plain.loads
    assert_equal fresh.context_tokens, whole.context_tokens
    assert_equal fresh.children.map(&:to_h), whole.children.map(&:to_h)
    assert_equal(fresh.pending_inbox.map { |entry| entry["type"] },
                 whole.pending_inbox.map { |entry| entry["type"] })
  end
end
