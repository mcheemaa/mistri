# frozen_string_literal: true

require "securerandom"
require "time"

module Mistri
  # The durable record of a run: an append-only log of typed entries over a
  # pluggable store. Messages replay into provider-ready history; other entry
  # types (reminders, custom host data) ride alongside without the loop
  # knowing their shapes.
  #
  # A store implements two methods: append(id, entry_hash) and load(id) ->
  # array of entry hashes in append order. Everything else lives here.
  class Session
    attr_reader :id, :store

    def initialize(store:, id: nil)
      @store = store
      @id = id || SecureRandom.uuid
    end

    def append_message(message)
      append("message", "message" => message.to_h)
      message
    end

    def append(type, data = {})
      @store.append(@id, { "type" => type, "at" => Time.now.utc.iso8601 }.merge(data))
      nil
    end

    def entries = @store.load(@id)

    # The conversation as the model replays it.
    def messages
      entries.filter_map do |entry|
        Message.from_h(entry["message"]) if entry["type"] == "message"
      end
    end
  end
end
