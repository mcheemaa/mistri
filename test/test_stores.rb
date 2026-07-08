# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

begin
  require "active_record"
  require_relative "../lib/mistri/stores/active_record"
rescue LoadError
  # The gem has zero runtime dependencies; ActiveRecord store coverage runs
  # only where activerecord is installed (the rails_test bundle group).
end

class TestStores < Minitest::Test
  def test_session_round_trips_messages_through_each_store
    each_store do |store|
      session = Mistri::Session.new(store:)
      session.append_message(Mistri::Message.user("hello"))
      session.append_message(Mistri::Message.assistant(content: "hi", stop_reason: :stop))
      session.append("reminder", "text" => "stay on task")

      reloaded = Mistri::Session.new(store:, id: session.id)

      assert_equal %i[user assistant], reloaded.messages.map(&:role)
      assert_equal "hello", reloaded.messages.first.text
      assert_equal 3, reloaded.entries.length
      assert_equal "stay on task", reloaded.entries.last["text"]
    end
  end

  def test_stores_isolate_sessions_by_id
    each_store do |store|
      Mistri::Session.new(store:, id: "one").append_message(Mistri::Message.user("a"))
      Mistri::Session.new(store:, id: "two").append_message(Mistri::Message.user("b"))

      assert_equal "a", Mistri::Session.new(store:, id: "one").messages.first.text
      assert_equal 1, Mistri::Session.new(store:, id: "two").entries.length
    end
  end

  def test_a_tool_message_with_an_image_survives_persistence
    each_store do |store|
      image = Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
      session = Mistri::Session.new(store:)
      session.append_message(Mistri::Message.user(["look", image]))

      block = Mistri::Session.new(store:, id: session.id).messages.first.content.last

      assert_equal "image/png", block.mime_type
      assert_equal "png!", block.bytes
    end
  end

  private

  def each_store
    yield Mistri::Stores::Memory.new
    Dir.mktmpdir { |dir| yield Mistri::Stores::JSONL.new(dir) }
  end
end

if defined?(Mistri::Stores::ActiveRecord)
  # A model standing in for the host's table, faithful to the one contract
  # the store leans on: the unique (session_id, position) index. Uniqueness
  # is checked under a lock, exactly as the database would.
  class FakeEntryModel
    Row = Struct.new(:session_id, :position, :payload)

    def initialize
      @rows = []
      @mutex = Mutex.new
      @before_insert = nil
    end

    # Runs inside the insert lock, before uniqueness is checked: a hook a
    # test uses to slip a competing row in, deterministically.
    def race_once(&block)
      @before_insert = block
    end

    def where(session_id:)
      rows = @mutex.synchronize { @rows.select { |row| row.session_id == session_id }.dup }
      Scope.new(rows)
    end

    def create!(session_id:, position:, payload:)
      @mutex.synchronize do
        if (hook = @before_insert)
          @before_insert = nil
          hook.call
        end
        if @rows.any? { |row| row.session_id == session_id && row.position == position }
          raise ::ActiveRecord::RecordNotUnique, "duplicate (#{session_id}, #{position})"
        end

        @rows << Row.new(session_id, position, payload)
      end
    end

    def insert_bare(session_id, position)
      @rows << Row.new(session_id, position, "{}")
    end

    class Scope
      def initialize(rows) = @rows = rows

      def maximum(_column) = @rows.map(&:position).max

      def pluck(*) = @rows.map { |row| [row.position, row.payload] }
    end
  end

  # The optimistic append: writers that collide on the unique index retry
  # at the next position, because sessions have concurrent appenders by
  # design (the loop, a steer from another process, a child's report).
  class TestActiveRecordStore < Minitest::Test
    def setup
      @model = FakeEntryModel.new
      @store = Mistri::Stores::ActiveRecord.new(@model)
    end

    def test_appends_and_loads_in_position_order
      @store.append("s", { "type" => "message", "n" => 1 })
      @store.append("s", { "type" => "message", "n" => 2 })

      numbers = @store.load("s").map { |entry| entry["n"] }

      assert_equal [1, 2], numbers
    end

    def test_a_losing_writer_retries_at_the_next_position
      @store.append("s", { "n" => 1 })
      # Another process appends between this writer's max(position) read
      # and its insert; the index rejects the stale position and the
      # retry lands cleanly after the winner.
      @model.race_once { @model.insert_bare("s", 2) }

      @store.append("s", { "n" => 3 })

      assert_equal 3, @store.load("s").length
      assert_equal({ "n" => 3 }, @store.load("s").last)
    end

    def test_concurrent_appenders_all_land_with_unique_positions
      threads = Array.new(4) do |writer|
        Thread.new do
          5.times { |n| @store.append("s", { "writer" => writer, "n" => n }) }
        end
      end
      threads.each(&:join)

      entries = @store.load("s")

      assert_equal 20, entries.length
      positions = @model.where(session_id: "s").pluck.map(&:first)

      assert_equal positions.uniq, positions
    end

    def test_gives_up_loudly_when_the_slot_never_frees
      # A pathological model that reports the same max forever: every
      # attempt collides, so the append must surface the conflict rather
      # than spin.
      @model.define_singleton_method(:create!) do |**|
        raise ::ActiveRecord::RecordNotUnique, "always"
      end

      assert_raises(::ActiveRecord::RecordNotUnique) { @store.append("s", { "n" => 1 }) }
    end
  end
end
