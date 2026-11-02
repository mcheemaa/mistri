# frozen_string_literal: true

require_relative "test_helper"

# Remembers where each load started, so a test can see which reads the
# session bounds.
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
    @session.messages
    @session.messages
    @session.context_tokens
    @session.pending_inbox
    @session.compaction_failures
    @session.last_compaction

    assert_equal [0, 3, 3, 3, 3, 3], @store.loads
  end

  def test_the_audit_read_teaches_the_boundary_too
    @session.tool_call_ids
    @session.messages

    assert_equal [0, 3], @store.loads
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

  def test_a_later_compaction_moves_the_boundary_forward
    @session.messages
    @session.append_message(Mistri::Message.assistant(content: "more", stop_reason: :stop))
    @session.append("compaction", "summary" => "later context", "kept_from" => 8)
    @session.messages
    @store.loads.clear

    @session.messages

    assert_equal [8], @store.loads
  end
end
