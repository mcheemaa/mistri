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

  # Appends made inside #transaction vanish when it is rolled back, as rows
  # do in a database transaction.
  class TransactionalStore < Mistri::Stores::Memory
    class Rollback < StandardError; end

    def settled? = !@open

    def transaction
      saved = @mutex.synchronize { @entries.to_h { |id, entries| [id, entries.dup] } }
      @open = true
      yield
    rescue Rollback
      @mutex.synchronize { @entries.each_key { |id| @entries[id] = saved.fetch(id, []) } }
    ensure
      @open = false
    end
  end

  # Serves the thread that pinned it a copy of the log from that moment, as
  # a REPEATABLE READ transaction does on its connection.
  class SnapshotStore < Mistri::Stores::Memory
    def pin
      copy = @mutex.synchronize { @entries.to_h { |id, entries| [id, entries.dup] } }
      Thread.current.thread_variable_set(:pinned, copy)
    end

    def unpin = Thread.current.thread_variable_set(:pinned, nil)

    def settled? = Thread.current.thread_variable_get(:pinned).nil?

    def load(id, from: 0)
      pinned = Thread.current.thread_variable_get(:pinned)
      return super unless pinned

      pinned.fetch(id, []).drop(from).map { |entry| json_copy(entry, freeze: false) }
    end
  end

  # A store written before partial reads: append and load(id), nothing else.
  class PlainStore
    attr_reader :loads

    def initialize
      @store = Mistri::Stores::Memory.new
      @loads = 0
    end

    def append(id, entry) = @store.append(id, entry)

    def load(id)
      @loads += 1
      @store.load(id)
    end
  end

  # Holds one load inside the store until the test lets it go.
  class GatedStore < Mistri::Stores::Memory
    attr_reader :entered, :starts

    def initialize
      super
      @entered = Queue.new
      @gate = Queue.new
      @starts = []
    end

    def hold_next_load = @hold = true

    def release = @gate << true

    def load(id, from: 0)
      @starts << from
      if @hold
        @hold = false
        @entered << true
        @gate.pop
      end
      super
    end
  end

  READS = {
    replay: ->(session) { session.replay.map { |message, index| [message.to_h, index] } },
    context_tokens: lambda(&:context_tokens),
    inbox: lambda(&:pending_inbox),
    last_compaction: lambda(&:last_compaction),
    compaction_failures: ->(session) { session.compaction_failures(trigger: :automatic) },
    children: ->(session) { session.children.map(&:to_h) },
    tool_call_ids: lambda(&:tool_call_ids),
    approvals: lambda do |session|
      session.open_approvals.map { |open| [open[:call].to_h, open[:decision]] }
    end
  }.freeze

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

  def test_an_append_through_another_session_object_is_seen_by_the_next_read
    exchange("first")
    @session.messages
    Mistri::Session.new(store: @store, id: @session.id).steer("from elsewhere")

    texts = @session.pending_steers.map { |entry| entry.dig("message", "content", 0, "text") }

    assert_equal ["from elsewhere"], texts
  end

  def test_every_answer_matches_one_read_from_the_whole_log
    script.each do |step|
      step.call

      READS.each do |name, read|
        whole = read.call(Mistri::Session.new(store: @store, id: @session.id))

        assert_equal [whole], [read.call(@session)], "#{name} differs from the whole log"
      end
    end
  end

  def test_a_decision_that_is_rolled_back_is_not_kept
    store = TransactionalStore.new
    session = Mistri::Session.new(store:)
    park_an_approval("call_a", session)
    session.open_approvals

    store.transaction do
      session.approve("call_a")

      assert session.open_approvals.first[:decision]["approved"]
      raise TransactionalStore::Rollback
    end

    assert_nil session.open_approvals.first[:decision]
    session.deny("call_a")

    refute session.open_approvals.first[:decision]["approved"]
  end

  def test_a_read_inside_a_transaction_answers_from_its_own_view_of_the_store
    store = SnapshotStore.new
    session = Mistri::Session.new(store:)
    exchange("first", session)
    session.messages
    store.pin
    Thread.new do
      exchange("second", session)
      session.messages
    end.join

    assert_equal %w[first FIRST], session.messages.map(&:text)
    store.unpin

    assert_equal %w[first FIRST second SECOND], session.messages.map(&:text)
  ensure
    store&.unpin
  end

  def test_a_store_with_only_append_and_load_is_read_whole_every_time
    store = PlainStore.new
    session = Mistri::Session.new(store:)
    exchange("first", session)
    session.messages
    exchange("second", session)

    assert_equal %w[first FIRST second SECOND], session.messages.map(&:text)
    assert_equal 2, store.loads
  end

  def test_changing_the_string_a_session_was_given_does_not_move_the_session
    other = Mistri::Session.new(store: @store, id: "other")
    other.append_message(Mistri::Message.user("from the other session"))
    id = +"first"
    session = Mistri::Session.new(store: @store, id:)
    session.append_message(Mistri::Message.user("from first"))
    session.messages

    id.replace("other")
    session.append_message(Mistri::Message.user("more from first"))

    assert_equal ["from first", "more from first"], session.messages.map(&:text)
    assert_equal ["from the other session"], other.messages.map(&:text)
  end

  def test_the_id_a_session_returns_is_a_copy_the_caller_owns
    session = Mistri::Session.new(store: @store, id: +"first")
    session.append_message(Mistri::Message.user("from first"))

    session.id << " changed"

    assert_equal "first", session.id
    assert_equal ["from first"], session.messages.map(&:text)
  end

  def test_the_id_returned_for_a_frozen_string_can_be_changed
    session = Mistri::Session.new(store: @store, id: "first")

    session.id << " changed"

    assert_equal "first", session.id
  end

  def test_a_session_keeps_an_id_that_is_not_a_string
    session = Mistri::Session.new(store: @store, id: 42)
    session.append_message(Mistri::Message.user("numbered"))

    assert_equal 42, session.id
    assert_equal ["numbered"], session.messages.map(&:text)
  end

  def test_an_id_that_is_not_a_string_stays_the_object_it_was
    key = Object.new
    Mistri::Session.new(store: @store, id: key).append_message(Mistri::Message.user("earlier"))

    session = Mistri::Session.new(store: @store, id: key)
    session.append_message(Mistri::Message.user("later"))

    assert_same key, session.id
    assert_equal %w[earlier later], session.messages.map(&:text)
    assert_equal 2, @store.load(key).length
  end

  def test_an_array_id_is_not_copied
    key = ["tenant", 7]
    session = Mistri::Session.new(store: @store, id: key)

    assert_same key, session.id
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

  def test_a_replayed_message_is_a_value_the_caller_owns
    @session.append("message", "message" => {
                      "role" => "assistant", "content" => [{ "type" => "text", "text" => "done" }],
                      "model" => "model-1", "stop_reason" => "stop",
                      "ui" => { "card" => { "title" => "Report" } },
                      "error" => { "detail" => { "code" => "none" } }
                    })
    message = @session.messages.first

    message.ui["card"]["title"] << " changed"
    message.to_h[:error]["detail"]["code"] << " changed"
    message.model << " changed"
    again = @session.messages.first

    assert_equal "Report", again.ui.dig("card", "title")
    assert_equal "none", again.error.dig("detail", "code")
    assert_equal "model-1", again.model
  end

  def test_a_child_is_a_value_the_caller_owns
    @session.append("subagent", "name" => "Magpie", "session_id" => "child-1")
    child = @session.children.first

    child.name << " changed"
    child.to_h["session_id"] << " changed"
    again = @session.children.first

    assert_equal %w[Magpie child-1], [again.name, again.session_id]
  end

  def test_a_second_reader_waits_and_reads_only_what_the_first_did_not
    store = GatedStore.new
    session = Mistri::Session.new(store:)
    exchange("first", session)
    store.hold_next_load
    first = Thread.new { session.messages.length }
    store.entered.pop
    second = Thread.new { session.messages.length }
    wait_until { second.status == "sleep" }

    assert_equal [0], store.starts
    store.release

    assert_equal [2, 2], [first.value, second.value]
    assert_equal [0, 2], store.starts
  ensure
    store&.release
    [first, second].compact.each(&:join)
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

  # One session that meets a steer, a child report, an approval, a denial, an
  # unanswered call, a failed and a successful compaction.
  def script
    [-> { exchange("first") },
     -> { @session.steer("while busy") },
     -> { fold_inbox },
     -> { @session.append("subagent", "name" => "Magpie", "session_id" => "child-1") },
     -> { report_from("child-1") },
     -> { fold_inbox },
     -> { park_an_approval("call_a") },
     -> { @session.approve("call_a") },
     -> { answer("call_a", "sent") },
     -> { park_an_approval("call_b") },
     -> { @session.deny("call_b", note: "not now") },
     -> { answer("call_b", "denied") },
     -> { leave_a_call_unanswered },
     -> { exchange("second") },
     -> { @session.append("compaction_failed", "reason" => "empty", "trigger" => "automatic") },
     -> { compact },
     -> { exchange("third") }]
  end

  def exchange(text, session = @session)
    session.append_message(Mistri::Message.user(text))
    session.append_message(Mistri::Message.assistant(content: text.upcase, stop_reason: :stop))
  end

  def fold_inbox
    @session.pending_inbox.each do |entry|
      marker = Mistri::Session::INBOX.fetch(entry["type"])
      @session.append("message", "message" => entry["message"], marker => entry["id"])
    end
  end

  def report_from(child_id)
    @session.deliver_report(name: "Magpie", session_id: child_id, status: "done", text: "found")
  end

  def park_an_approval(id, session = @session)
    call = Mistri::ToolCall.new(id:, name: "send", arguments: { "to" => "ops" })
    session.append_message(Mistri::Message.user("send it"))
    session.append_message(Mistri::Message.assistant(content: [call], stop_reason: :tool_use))
    session.append("approval_request", "call" => JSON.parse(JSON.generate(call.to_h)))
  end

  def answer(id, text)
    @session.append_message(Mistri::Message.tool(content: text, tool_call_id: id,
                                                 tool_name: "send"))
  end

  def leave_a_call_unanswered
    call = Mistri::ToolCall.new(id: "call_lost", name: "send", arguments: {})
    @session.append_message(Mistri::Message.user("and again"))
    @session.append_message(Mistri::Message.assistant(content: [call], stop_reason: :tool_use))
  end

  def compact
    provider = Mistri::Providers::Fake.new(turns: [{ text: "1. Goal and requests\nKeep going.\n" }])
    settings = Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 1)

    assert Mistri::Compactor.call(session: @session, provider:, settings:)
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
