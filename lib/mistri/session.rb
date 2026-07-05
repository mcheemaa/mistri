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
    def messages = replay.map(&:first)

    # What a run killed mid-tool answers in place of the result it never got.
    INTERRUPTED_RESULT = "[interrupted: the run stopped before this tool returned]"

    # Replay messages paired with the entry index each came from, starting at
    # the latest compaction boundary. The synthetic summary message carries a
    # nil index. Compaction places its cuts by these indexes; the full entry
    # log stays in the store for transcript views. One store read builds the
    # whole context, healed: a crash that left tool calls unanswered would
    # brick every later turn with a provider rejection, so unsettled calls
    # get a synthesized interrupted result. Calls parked for human approval
    # stay open; resume owns those.
    def replay
      log = entries
      compaction = log.reverse_each.find { |entry| entry["type"] == "compaction" }
      from = compaction ? compaction["kept_from"] : 0
      pairs = log.each_with_index.filter_map do |entry, index|
        [Message.from_h(entry["message"]), index] if index >= from && entry["type"] == "message"
      end
      pairs = heal(pairs, parked_call_ids(log))
      compaction ? [[summary_message(compaction["summary"]), nil], *pairs] : pairs
    end

    def last_compaction
      entries.reverse_each.find { |entry| entry["type"] == "compaction" }
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

    def heal(pairs, parked)
      answered = pairs.map(&:first).select(&:tool?).to_set(&:tool_call_id)
      pairs.flat_map do |message, index|
        dangling = if message.assistant?
                     message.tool_calls.reject do |call|
                       answered.include?(call.id) || parked.include?(call.id)
                     end
                   else
                     []
                   end
        [[message, index]] + dangling.map do |call|
          [Message.tool(content: INTERRUPTED_RESULT, tool_call_id: call.id,
                        tool_name: call.name), nil]
        end
      end
    end

    def parked_call_ids(log)
      log.filter_map { |entry| entry.dig("call", "id") if entry["type"] == "approval_request" }
         .to_set
    end

    def summary_message(summary)
      Message.user("#{Compaction::SUMMARY_PREFACE}\n\n#{summary}")
    end

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
