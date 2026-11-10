# frozen_string_literal: true

require_relative "test_helper"

class TestSessionLog < Minitest::Test
  # Records where each load starts and how many entries it returns.
  class RecordingStore < Mistri::Stores::Memory
    Read = Data.define(:from, :entries)

    attr_reader :reads

    def initialize
      super
      @reads = []
    end

    def load(id, from: 0)
      super.tap { |entries| @reads << Read.new(from:, entries: entries.length) }
    end
  end

  def setup
    @store = RecordingStore.new
    @session = Mistri::Session.new(store: @store)
  end

  def test_a_session_reads_the_log_once_and_then_only_what_is_new
    exchange("first")
    @session.messages
    exchange("second")
    @session.messages
    @session.pending_inbox

    assert_equal [0, 2, 4], @store.reads.map(&:from)
    assert_equal [2, 2, 0], @store.reads.map(&:entries)
  end

  def test_a_run_reads_each_entry_from_the_store_once
    40.times { |n| exchange("earlier #{n}") }
    ping = Mistri::Tool.define("ping", "Ping.") { "pong" }
    turns = Array.new(3) { { tool_calls: [{ name: "ping", arguments: {} }] } } + [{ text: "done" }]
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), session: @session,
                              tools: [ping])

    agent.run("go")

    read = @store.reads.sum(&:entries)
    @store.reads.clear

    assert_equal @store.load(@session.id).length, read
  end

  def test_an_append_from_another_process_is_seen_by_the_next_read
    exchange("first")
    @session.messages
    Mistri::Session.new(store: @store, id: @session.id).steer("from elsewhere")

    texts = @session.pending_steers.map { |entry| entry.dig("message", "content", 0, "text") }

    assert_equal ["from elsewhere"], texts
  end

  def test_every_answer_matches_a_session_that_reads_the_whole_log
    steps = [
      -> { exchange("first") },
      -> { @session.steer("while busy") },
      -> { fold_inbox },
      -> { park_an_approval },
      -> { @session.approve("call_a") },
      -> { settle_the_approval },
      -> { exchange("second") },
      -> { compact },
      -> { exchange("third") }
    ]

    steps.each do |step|
      step.call

      assert_equal answers(Mistri::Session.new(store: @store, id: @session.id)), answers(@session)
    end
  end

  def test_entries_returns_copies_the_caller_owns
    exchange("first")
    @session.messages

    @session.entries.first["message"]["content"].first["text"] << " changed"

    assert_equal "first", @session.messages.first.text
  end

  def test_inbox_and_compaction_entries_are_copies_the_caller_owns
    @session.steer("queued")
    @session.append("compaction", "summary" => "earlier", "kept_from" => 0)

    @session.pending_inbox.first["message"]["content"].first["text"] << " changed"
    @session.last_compaction["summary"] << " changed"

    assert_equal "queued", @session.pending_inbox.first.dig("message", "content", 0, "text")
    assert_equal "earlier", @session.last_compaction["summary"]
  end

  def test_readers_on_many_threads_share_one_consistent_log
    writer = Thread.new { 200.times { |n| @session.append_message(Mistri::Message.user("m#{n}")) } }
    readers = Array.new(8) do
      Thread.new { Array.new(50) { @session.messages.map(&:text) } }
    end

    writer.join
    seen = readers.flat_map(&:value)
    expected = Array.new(200) { |n| "m#{n}" }

    assert(seen.all? { |texts| texts == expected.first(texts.length) })
    assert_equal expected, @session.messages.map(&:text)
  end

  private

  def exchange(text)
    @session.append_message(Mistri::Message.user(text))
    @session.append_message(Mistri::Message.assistant(content: text.upcase, stop_reason: :stop))
  end

  def fold_inbox
    @session.pending_inbox.each do |entry|
      marker = Mistri::Session::INBOX.fetch(entry["type"])
      @session.append("message", "message" => entry["message"], marker => entry["id"])
    end
  end

  def park_an_approval
    call = Mistri::ToolCall.new(id: "call_a", name: "send", arguments: { "to" => "ops" })
    @session.append_message(Mistri::Message.assistant(content: [call], stop_reason: :tool_use))
    @session.append("approval_request", "call" => JSON.parse(JSON.generate(call.to_h)))
  end

  def settle_the_approval
    @session.append_message(Mistri::Message.tool(content: "sent", tool_call_id: "call_a",
                                                 tool_name: "send"))
  end

  def compact
    provider = Mistri::Providers::Fake.new(turns: [{ text: "1. Goal and requests\nKeep going.\n" }])
    settings = Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 1)

    assert Mistri::Compactor.call(session: @session, provider:, settings:)
  end

  def answers(session)
    control = session.tool_control_state
    { messages: session.messages.map(&:to_h),
      context_tokens: session.context_tokens,
      inbox: session.pending_inbox,
      last_compaction: session.last_compaction,
      compaction_failures: session.compaction_failures,
      children: session.children.map(&:to_h),
      tool_call_ids: control.fetch(:tool_call_ids),
      approvals: control.fetch(:approvals).map { |open| [open[:call].to_h, open[:decision]] } }
  end
end
