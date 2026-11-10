# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/session_stores"

# A session starts at its newest checkpoint: the loop reads and derives from
# there, and the checkpoint carries what it needs from before.
class TestSessionCheckpoint < Minitest::Test
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
    exchange("after")
    @session.checkpoint(summary: "One.", kept_from: 4)
    exchange("later")
    @session.checkpoint(summary: "Two.", kept_from: 7)
    before = @store.size("s")

    refute fresh.deliver_report(**report)
    refute @session.deliver_report(**report)
    assert_equal before, @store.size("s")
  end

  def test_a_compaction_carries_the_children_it_cuts_away
    link("Magpie", "c1")
    3.times { |n| exchange("turn #{n}") }

    compact

    entry = @session.last_compaction

    assert_equal [{ "name" => "Magpie", "session_id" => "c1" }], entry.dig("carried", "children")
    assert_empty entry.dig("carried", "reported")
    assert_equal %w[Magpie], fresh.children.map(&:name)
  end

  def test_a_cut_steps_back_before_a_steer_that_is_not_folded_in
    2.times { |n| exchange("before #{n}") }
    @session.steer("hold on")
    2.times { |n| exchange("after #{n}") }

    compact
    pending = fresh.pending_inbox.map { |entry| entry.dig("message", "content", 0, "text") }

    assert_equal 2, @session.last_compaction["kept_from"]
    assert_equal ["hold on"], pending
  end

  def test_a_cut_is_not_held_back_once_the_steer_is_folded_in
    2.times { |n| exchange("before #{n}") }
    @session.steer("hold on")
    steer = @session.pending_inbox.first
    @session.append("message", "message" => steer["message"], "steer_id" => steer["id"])
    2.times { |n| exchange("after #{n}") }

    compact

    assert_equal 8, @session.last_compaction["kept_from"]
    assert_empty fresh.pending_inbox
  end

  def test_a_decision_for_a_call_older_than_the_window_finds_no_open_approval
    gated = Mistri::Tool.define("gated", "Needs a person.", needs_approval: true) { "ran" }
    turns = [{ tool_calls: [{ name: "gated", arguments: {} }] }, { text: "done" }]
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), session: @session,
                              tools: [gated])
    call_id = agent.run("go").pending.first.id
    @session.approve(call_id)
    agent.resume
    exchange("after")

    assert_nil @session.approve(call_id)
    @session.checkpoint(summary: "Earlier.", kept_from: @store.size("s") - 2)

    error = assert_raises(Mistri::ConfigurationError) { fresh.approve(call_id) }
    assert_match(/no open approval/, error.message)
  end

  def test_a_tool_call_id_from_before_the_window_may_be_used_again
    call("same")
    exchange("between")
    @session.checkpoint(summary: "Earlier.", kept_from: 2)
    call("same")

    assert_equal %w[same], fresh.tool_call_ids.to_a
    assert_equal 5, fresh.messages.length
  end

  def test_an_unreadable_entry_older_than_the_window_does_not_stop_the_session
    @store.append("s", { "type" => "message", "message" => { "role" => "nobody" } })
    exchange("after")
    @session.checkpoint(summary: "Earlier.", kept_from: 1)

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

  private

  def fresh = Mistri::Session.new(store: @store, id: "s")

  def compact
    summarizer = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    Mistri::Compactor.call(session: @session, provider: summarizer,
                           settings: Mistri::Compaction.new(keep_recent: 1))
  end

  def exchange(text, session = @session)
    session.append_message(Mistri::Message.user(text))
    session.append_message(Mistri::Message.assistant(content: text.upcase, stop_reason: :stop))
  end

  def link(name, session_id, session = @session)
    session.append("subagent", "name" => name, "session_id" => session_id)
  end

  def call(id)
    tool_call = Mistri::ToolCall.new(id:, name: "ping", arguments: {})
    @session.append_message(Mistri::Message.assistant(tool_calls: [tool_call]))
    @session.append_message(Mistri::Message.tool(content: "pong", tool_call_id: id,
                                                 tool_name: "ping"))
  end
end
