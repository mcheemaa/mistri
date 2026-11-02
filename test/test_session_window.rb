# frozen_string_literal: true

require_relative "test_helper"

# Records where each load starts.
class RecordingStore < Mistri::Stores::Memory
  attr_reader :loads

  def initialize
    super
    @loads = []
  end

  def load(id, from: 0)
    @loads << from
    super
  end
end

class TestSessionWindow < Minitest::Test
  def setup
    @store = RecordingStore.new
    @session = Mistri::Session.new(store: @store)
    @session.append_message(Mistri::Message.user("old"))
    @session.append("steer", "id" => "s1", "message" => Mistri::Message.user("folded").to_h)
    @session.append("message", "message" => Mistri::Message.user("folded").to_h, "steer_id" => "s1")
    @session.append_message(Mistri::Message.assistant(content: "then", stop_reason: :stop))
    @session.append_message(Mistri::Message.user("recent"))
    @session.append("compaction", "summary" => "earlier context", "kept_from" => 3)
    @session.append("compaction_failed", "reason" => "empty summary", "trigger" => "automatic")
    @session.append("steer", "id" => "s2", "message" => Mistri::Message.user("later").to_h)
  end

  def test_the_first_read_is_full_and_every_read_after_it_starts_at_the_boundary
    @session.tool_call_ids
    @session.messages
    @session.context_tokens
    @session.pending_inbox
    @session.compaction_failures
    @session.last_compaction

    assert_equal [0, 3, 3, 3, 3, 3], @store.loads
  end

  def test_the_full_log_stays_available_to_readers
    @session.messages
    @store.loads.clear

    @session.entries
    @session.transcript

    assert_equal [0, 0], @store.loads
  end

  def test_a_bounded_read_answers_the_same_as_a_full_one
    fresh = Mistri::Session.new(store: @store, id: @session.id)
    @session.messages

    assert_equal fresh.messages.map(&:to_h), @session.messages.map(&:to_h)
    assert_equal fresh.context_tokens, @session.context_tokens
    assert_equal(["s2"], @session.pending_inbox.map { |entry| entry["id"] })
    assert_equal 1, @session.compaction_failures(trigger: :automatic)
    assert_equal 3, @session.last_compaction["kept_from"]
  end

  def test_a_compaction_never_cuts_past_a_queued_steer
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    %w[first second].each { |text| exchange(session, text) }
    session.steer("while idle")
    exchange(session, "third")
    session.append_message(Mistri::Message.user("fourth"))
    provider = Mistri::Providers::Fake.new(turns: [{ text: "1. Goal and requests\nKeep going.\n" }])
    settings = Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 1)

    Mistri::Compactor.call(session:, provider:, settings:)

    assert_equal 2, session.last_compaction.fetch("kept_from")
    assert_equal 1, session.pending_steers.length
  end

  def test_the_boundary_never_passes_an_unfolded_steer
    store = RecordingStore.new
    session = Mistri::Session.new(store:)
    session.append_message(Mistri::Message.user("old"))
    session.append("steer", "id" => "s1", "message" => Mistri::Message.user("missed").to_h)
    session.append_message(Mistri::Message.assistant(content: "then", stop_reason: :stop))
    session.append_message(Mistri::Message.user("recent"))
    session.append("compaction", "summary" => "cut past the steer", "kept_from" => 3)
    session.tool_call_ids

    pending = session.pending_inbox

    assert_equal(["s1"], pending.map { |entry| entry["id"] })
    assert_equal [0, 1], store.loads
  end

  def test_a_later_compaction_moves_the_boundary_forward
    @session.messages
    @session.append("message", "message" => Mistri::Message.user("later").to_h, "steer_id" => "s2")
    @session.append_message(Mistri::Message.assistant(content: "more", stop_reason: :stop))
    @session.append("compaction", "summary" => "later context", "kept_from" => 9)
    @session.messages
    @store.loads.clear

    @session.messages

    assert_equal [9], @store.loads
  end

  private

  def exchange(session, text)
    session.append_message(Mistri::Message.user(text))
    session.append_message(Mistri::Message.assistant(content: text.upcase, stop_reason: :stop))
  end
end
