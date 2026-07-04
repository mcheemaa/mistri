# frozen_string_literal: true

require "json"
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

    # Entries are normalized through JSON at write time, so every store holds
    # the same canonical shape (string keys, JSON values) and reads behave
    # identically whether the entry round-tripped a database or stayed in
    # memory.
    def append(type, data = {})
      entry = { "type" => type, "at" => Time.now.utc.iso8601 }.merge(data)
      @store.append(@id, JSON.parse(JSON.generate(entry)))
      nil
    end

    def entries = @store.load(@id)

    # The conversation as the model replays it.
    def messages
      entries.filter_map do |entry|
        Message.from_h(entry["message"]) if entry["type"] == "message"
      end
    end

    # Queue a message for a running exchange from any process. The loop folds
    # pending steers into the transcript at the next turn boundary, so the
    # model sees them mid-run; one that arrives as the model finishes cleanly
    # extends the run another turn so it is answered, not left dangling.
    def steer(text)
      append("steer", "id" => SecureRandom.uuid, "message" => Message.user(text).to_h)
    end

    # Steers not yet folded into the transcript, oldest first. The folding
    # message entry carries the steer id, so consumption is derived from the
    # log alone and reads the same from every process.
    def pending_steers
      folded = entries.filter_map { |entry| entry["steer_id"] }
      entries.select { |entry| entry["type"] == "steer" && !folded.include?(entry["id"]) }
    end

    # Record a human's decision on a parked tool call. Decisions are session
    # entries, so they can be written from any process, days later, with no
    # agent constructed; the next resume settles them.
    def approve(call_id, note: nil) = decide(call_id, approved: true, note: note)

    def deny(call_id, note: nil) = decide(call_id, approved: false, note: note)

    # Parked tool calls not yet settled by a tool result, each with its
    # decision when one has been recorded. Derived from the entry log alone,
    # so it survives crashes and reads the same from every process.
    def open_approvals
      answered = []
      decisions = {}
      requests = []
      entries.each do |entry|
        case entry["type"]
        when "message"
          call_id = entry.dig("message", "tool_call_id")
          answered << call_id if call_id
        when "approval_request" then requests << entry["call"]
        when "approval_decision" then decisions[entry["call_id"]] = entry
        end
      end
      requests.reject { |call| answered.include?(call["id"]) }
              .map { |call| { call: rebuild_call(call), decision: decisions[call["id"]] } }
    end

    private

    def decide(call_id, approved:, note:)
      unless open_approvals.any? { |open| open[:call].id == call_id }
        raise ConfigurationError, "no open approval for #{call_id.inspect}"
      end

      entry = { "call_id" => call_id, "approved" => approved }
      entry["note"] = note if note
      append("approval_decision", entry)
    end

    def rebuild_call(hash)
      ToolCall.new(id: hash["id"], name: hash["name"],
                   arguments: hash["arguments"] || {}, signature: hash["signature"])
    end
  end
end
