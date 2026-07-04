# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

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
