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
  class Session # rubocop:disable Metrics/ClassLength -- append-only ordering is the class contract
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

    # Every call ID is a session-wide correlation key. Read and validate the
    # append-only history once, returning an owned set the loop can extend as
    # it accepts later turns. Approval control entries are audited in the same
    # ordered pass: they may only advance a prior assistant call.
    def tool_control_state
      audited = audit_history(entries)
      approvals = audited.fetch(:approvals).map do |approval|
        decision = approval[:decision] && own_json(approval[:decision])
        { call: rebuild_call(approval[:call]), decision: }
      end
      { tool_call_ids: audited.fetch(:tool_call_ids), approvals: }
    end

    def tool_call_ids = tool_control_state.fetch(:tool_call_ids)

    # The conversation as the model replays it.
    def messages = replay.map(&:first)

    # What a run killed mid-tool answers in place of the result it never got.
    INTERRUPTED_RESULT = "[interrupted: the run stopped before this result was persisted; " \
                         "the tool may have executed, so verify its effects before retrying]"
    LEGACY_CALL_ID = /\Acall_[1-9]\d*\z/
    LEGACY_CALL_PROVIDERS = %i[fake gemini].freeze
    private_constant :LEGACY_CALL_ID, :LEGACY_CALL_PROVIDERS

    # Replay messages paired with the entry index each came from, starting at
    # the latest compaction boundary. The synthetic summary message carries a
    # nil index. Compaction places its cuts by these indexes; the full entry
    # log stays in the store for transcript views. One store read builds the
    # whole context, healed: a crash that left tool calls unanswered would
    # brick every later turn with a provider rejection, so unsettled calls
    # get a synthesized interrupted result. Calls parked for human approval
    # stay open; resume owns those.
    def replay = replay_from(entries)

    # Context accounting ignores provider usage reported before the latest
    # compaction: those prompt counts describe the larger, pre-summary replay.
    # Until a post-compaction assistant turn reports fresh usage, the compacted
    # replay is estimated directly.
    def context_tokens
      log = entries
      replay = replay_from(log)
      compacted_at = log.rindex { |entry| entry["type"] == "compaction" }
      usage_from = if compacted_at
                     replay.index { |(_, index)| index && index > compacted_at } || replay.length
                   else
                     0
                   end
      Compaction.context_tokens(replay.map(&:first), usage_from:)
    end

    def last_compaction
      entries.reverse_each.find { |entry| entry["type"] == "compaction" }
    end

    # The inbox: entry types queued for the loop's next turn boundary, each
    # mapped to the marker key its fold leaves on the consuming message
    # entry.
    INBOX = { "steer" => "steer_id", "subagent_report" => "report_id" }.freeze

    # Queue a message for a running exchange from any process. The loop folds
    # pending steers into the transcript at the next turn boundary, so the
    # model sees them mid-run; one that arrives as the model finishes cleanly
    # extends the run another turn so it is answered, not left dangling.
    def steer(text)
      append("steer", "id" => SecureRandom.uuid, "message" => Message.user(text).to_h)
    end

    # A sub-agent's report, queued for this session the way a steer is: it
    # folds into the transcript at the next turn boundary as a labeled block
    # the model can react to ("[Magpie finished] <report>"), while the typed
    # entry keeps name, status, and the raw text for hosts to render as a
    # report card rather than a fake user message. One report per child,
    # ever: a duplicate delivery (a redelivered queue job, a lease race) is
    # dropped, and the return says which happened. Reports normally arrive
    # via SubAgent.run_dispatched; call this directly only from a custom
    # dispatch path.
    def deliver_report(name:, session_id:, status:, text: nil) # rubocop:disable Naming/PredicateMethod
      already = entries.any? do |entry|
        entry["type"] == "subagent_report" && entry["session_id"] == session_id
      end
      return false if already

      append("subagent_report", "id" => SecureRandom.uuid, "name" => name,
                                "session_id" => session_id, "status" => status, "report" => text,
                                "message" => Message.user(report_label(name, status, text)).to_h)
      true
    end

    # Everything queued for the loop's next turn boundary (steers and
    # sub-agent reports), oldest first, in arrival order. The folding
    # message entry carries the source entry's id under its marker key, so
    # consumption is derived from the log alone and reads the same from
    # every process. A host that wakes an idle session when a steer arrives
    # should watch this instead: a report deserves the same pickup.
    def pending_inbox
      log = entries
      folded = log.flat_map { |entry| entry.values_at(*INBOX.values) }.compact.to_set
      log.select { |entry| INBOX.key?(entry["type"]) && !folded.include?(entry["id"]) }
    end

    # The steer-only slice of the inbox, oldest first.
    def pending_steers
      pending_inbox.select { |entry| entry["type"] == "steer" }
    end

    # Sub-agents this session has spawned, in spawn order: one Child window
    # per link entry, each reading the child's own session. Derived from the
    # log alone, like everything else here.
    def children
      entries.filter_map do |entry|
        next unless entry["type"] == "subagent"

        Child.new(name: entry["name"], session_id: entry["session_id"], store: @store)
      end
    end

    # The session as a reader renders it: entries in order with inline image
    # bytes stripped, and, with include_children, every sub-agent's own
    # transcript spliced in after its link entry. Spliced entries carry an
    # "origin" key shaped exactly like the live stream's event origins
    # ("Magpie#ab12cd34", nesting joined with ">"), so a UI that rebuilds
    # from this sees what it saw live, lanes included, running children's
    # progress-so-far included. The raw log stays available as #entries.
    def transcript(include_children: false)
      splice(entries, include_children: include_children, prefix: nil, seen: Set[@id])
    end

    # Record a human's decision on a parked tool call. Decisions are session
    # entries, so they can be written from any process, days later, with no
    # agent constructed; the next resume settles them.
    def approve(call_id, note: nil) = decide(call_id, approved: true, note: note)

    def deny(call_id, note: nil) = decide(call_id, approved: false, note: note)

    # Parked tool calls not yet settled by a tool result, each with its
    # decision when one has been recorded. Derived from the entry log alone,
    # so it survives crashes and reads the same from every process.
    def open_approvals = tool_control_state.fetch(:approvals)

    private

    def tool_calls_from(entry)
      Array(entry.dig("message", "content")).select do |block|
        block.is_a?(Hash) && block["type"].to_s == "tool_call"
      end
    end

    def record_assistant_calls(entry, message, index, audit)
      calls = audit.fetch(:calls)
      unresolved = audit.fetch(:unresolved)
      reserved = audit.fetch(:reserved)
      batch = { calls: [], provider_call_ids: {} }
      parsed_calls = message.tool_calls
      tool_calls_from(entry).each_with_index do |call, position|
        id = validated_persisted_call(call)
        source_call = parsed_calls.fetch(position)
        reused = reused_legacy_call(id, source_call, message.provider, calls, reserved)
        owned = id.dup.freeze
        provider_id = source_call.provider_call_id
        if provider_id && batch[:provider_call_ids].key?(provider_id)
          raise ConfigurationError, "session contains a duplicate provider tool call ID"
        end

        batch[:provider_call_ids][provider_id] = true if provider_id
        state = { source: call, source_call:,
                  source_provider: message.provider,
                  source_stop_reason: message.stop_reason,
                  source_index: index, source_position: position,
                  batch:, status: :pending, reused: !reused.nil? }
        calls[owned] = state
        batch[:calls] << state
        audit.fetch(:states) << state
        unresolved << owned
        reserved << owned
      end
    end

    # Gemini and Fake once synthesized call_N from a per-turn counter. Only
    # that known shape without provider correlation IDs may repeat; widening
    # the exception would turn the session correlation key back into a guess.
    def reused_legacy_call(id, source_call, provider, calls, reserved)
      return nil unless reserved.include?(id)

      prior = calls[id]
      safe_status = prior && %i[answered interrupted].include?(prior[:status])
      legacy_shape = LEGACY_CALL_ID.match?(id) && LEGACY_CALL_PROVIDERS.include?(provider) &&
                     LEGACY_CALL_PROVIDERS.include?(prior&.fetch(:source_provider, nil)) &&
                     source_call.provider_call_id.nil? &&
                     prior&.fetch(:source_call)&.provider_call_id.nil?
      unless safe_status && legacy_shape
        raise ConfigurationError, "session contains a duplicate tool call ID"
      end

      prior
    end

    def audit_history(log)
      calls = {}
      unresolved = Set.new
      reserved = Set.new
      states = []
      approval_ids = Set.new
      audit = { calls:, unresolved:, reserved:, states:, approval_ids: }
      latest_compaction = nil

      log.each_with_index do |entry, index|
        unless entry.is_a?(Hash)
          raise ConfigurationError, "session contains an entry that is not an object"
        end

        message = validate_message_entry!(entry) if entry["type"] == "message"

        if message&.tool?
          record_tool_result(entry, index, calls, unresolved)
        elsif message
          close_unsettled_calls(calls, unresolved)
          record_assistant_calls(entry, message, index, audit) if message.assistant?
        elsif entry["type"] == "approval_request"
          record_approval_call(entry, calls, audit)
        elsif entry["type"] == "approval_decision"
          record_approval_decision(entry, calls)
        elsif entry["type"] == "compaction"
          latest_compaction = entry
        end
      end

      interrupt_ambiguous_reused_approvals!(states)
      approvals = open_approval_states(states)
      validate_compaction!(audit, approvals, latest_compaction)
      { tool_call_ids: reserved, approvals: }
    end

    # Control entries can authorize side effects, so every message in the
    # same durable history must deserialize before any approval is exposed.
    def validate_message_entry!(entry)
      Message.from_h(entry["message"])
    rescue StandardError => e
      raise ConfigurationError,
            "session contains an invalid persisted message (#{e.class.name})"
    end

    def record_tool_result(entry, index, calls, unresolved)
      id = entry.dig("message", "tool_call_id")
      problem = required_string_problem(id, "tool result call IDs")
      raise ConfigurationError, "session contains #{problem}" if problem

      state = calls[id]
      unless state
        raise ConfigurationError, "session contains a tool result without a prior assistant " \
                                  "tool call"
      end

      name = entry.dig("message", "tool_name")
      problem = required_string_problem(name, "tool result names")
      raise ConfigurationError, "session contains #{problem}" if problem
      unless name == state[:source]["name"]
        raise ConfigurationError, "session contains a tool result whose name does not match " \
                                  "its assistant tool call"
      end

      case state[:status]
      when :pending
        if state[:batch][:approval_phase_started]
          raise ConfigurationError, "session contains a direct tool result after approval " \
                                    "settlement began"
        end
        advance_call_order!(state, :direct_result_position, "tool results")
        state[:status] = :answered
        state[:result_index] = index
        unresolved.delete(id)
      when :decided
        advance_call_order!(state, :approval_result_position, "approval tool results")
        state[:status] = :answered
        state[:result_index] = index
        unresolved.delete(id)
      when :approval_requested
        raise ConfigurationError, "session contains a tool result for an approval without a " \
                                  "prior decision"
      when :answered
        raise ConfigurationError, "session contains a duplicate tool result"
      when :interrupted
        raise ConfigurationError, "session contains a late tool result for a crash-healed call"
      end
    end

    def advance_call_order!(state, key, label)
      previous = state[:batch][key]
      if previous && state[:source_position] < previous
        raise ConfigurationError, "session contains #{label} out of assistant call order"
      end

      state[:batch][key] = state[:source_position]
    end

    def close_unsettled_calls(calls, unresolved)
      unresolved.each do |id|
        state = calls.fetch(id)
        if state[:ambiguous_approval] &&
           %i[approval_requested decided].include?(state[:status])
          state[:status] = :interrupted
          next
        end
        unless state[:status] == :pending
          raise ConfigurationError, "session continues past an unsettled approval"
        end

        state[:status] = :interrupted
      end
      unresolved.clear
    end

    def record_approval_call(entry, calls, audit)
      call = entry["call"]
      unless call.is_a?(Hash)
        raise ConfigurationError, "session contains an invalid approval request"
      end

      id = validated_persisted_call(call)
      state = calls[id]
      unless state
        raise ConfigurationError, "session contains an approval request without a prior " \
                                  "assistant tool call"
      end
      if state[:status] == :answered
        raise ConfigurationError, "session contains an approval request for an already " \
                                  "answered tool call"
      end
      if state[:status] == :interrupted
        raise ConfigurationError, "session contains a stale approval request for a " \
                                  "crash-healed tool call"
      end
      unless state[:status] == :pending
        raise ConfigurationError, "session contains a duplicate approval request ID"
      end
      unless state[:source_stop_reason] == StopReason::TOOL_USE
        raise ConfigurationError, "session contains an approval request for an assistant turn " \
                                  "that did not stop for tool use"
      end
      validate_gemini_approval_order!(state)
      validate_approval_provenance!(entry, call, state)

      advance_call_order!(state, :approval_request_position, "approval requests")
      state[:batch][:approval_phase_started] = true
      state[:status] = :approval_requested
      state[:approval] = { call:, decision: nil, source_index: state[:source_index] }
      state[:ambiguous_approval] = state[:reused] && audit.fetch(:approval_ids).include?(id)
      audit.fetch(:approval_ids) << id
    end

    def validate_approval_provenance!(entry, call, state)
      if entry["prepared_from"] == "assistant"
        validate_normalizable_source!(state)
        validate_prepared_call!(call, state[:source])
      elsif entry.key?("prepared_from")
        raise ConfigurationError, "session contains invalid approval provenance"
      elsif entry.key?("source_call")
        validate_approval_source!(entry["source_call"], call, state)
      elsif !approval_mirrors?(state[:source], call)
        raise ConfigurationError, "session contains an approval request that does not " \
                                  "match its assistant tool call"
      end
    end

    # Pre-ID Gemini calls pair same-name results by position. Once a later
    # sibling has answered, resuming an earlier side effect would make replay
    # ambiguous even when the durable history predates the live-run guard.
    def validate_gemini_approval_order!(state)
      source = state[:source_call]
      return unless state[:source_provider] == :gemini && source.provider_call_id.nil?

      unsafe = state[:batch][:calls].any? do |sibling|
        sibling[:source_position] > state[:source_position] && sibling[:status] == :answered &&
          sibling[:source_call].provider_call_id.nil? && sibling[:source_call].name == source.name
      end
      return unless unsafe

      raise ConfigurationError, "session contains an ambiguous Gemini approval after a later " \
                                "same-name tool result"
    end

    def record_approval_decision(entry, calls)
      id = entry["call_id"]
      problem = required_string_problem(id, "approval decision call IDs")
      raise ConfigurationError, "session contains #{problem}" if problem

      state = calls[id]
      unless state && state[:approval]
        raise ConfigurationError, "session contains an approval decision without a prior " \
                                  "matching approval request"
      end
      if state[:status] == :answered
        raise ConfigurationError, "session contains an approval decision for an already " \
                                  "answered tool call"
      end
      if state[:status] == :decided
        raise ConfigurationError, "session contains a duplicate approval decision"
      end
      unless state[:status] == :approval_requested
        raise ConfigurationError, "session contains an approval decision without a prior " \
                                  "matching approval request"
      end
      unless entry["approved"].equal?(true) || entry["approved"].equal?(false)
        raise ConfigurationError, "session contains an approval decision whose approved " \
                                  "value is not true or false"
      end

      state[:approval][:decision] = entry
      state[:status] = :decided
    end

    # An old decision names only call_N. Once that ID has already participated
    # in approval, a later unsettled approval cannot prove which generation a
    # delayed decision intended, so replay it as interrupted rather than risk
    # executing a side effect under stale authorization.
    def interrupt_ambiguous_reused_approvals!(states)
      states.each do |state|
        if state[:ambiguous_approval] && %i[approval_requested decided].include?(state[:status])
          state[:status] = :interrupted
        end
      end
    end

    def open_approval_states(states)
      states.filter_map do |state|
        state[:approval] if %i[approval_requested decided].include?(state[:status])
      end
    end

    def validate_compaction!(audit, approvals, compaction)
      return unless compaction

      kept_from = compaction["kept_from"]
      unless kept_from.is_a?(Integer) && kept_from >= 0
        raise ConfigurationError, "session contains an invalid compaction boundary"
      end
      if approvals.any? { |approval| approval[:source_index] < kept_from }
        raise ConfigurationError, "session contains an open approval whose assistant tool call " \
                                  "was removed by compaction"
      end
      split = audit.fetch(:states).any? do |state|
        state[:result_index] && state[:source_index] < kept_from &&
          state[:result_index] >= kept_from
      end
      return unless split

      raise ConfigurationError, "session contains a compaction boundary that splits a tool call " \
                                "from its result"
    end

    def validate_approval_source!(source, prepared, state)
      unless source.is_a?(Hash)
        raise ConfigurationError, "session contains an invalid approval source call"
      end

      validated_persisted_call(source)
      unless state[:source] && approval_mirrors?(state[:source], source)
        raise ConfigurationError, "session contains an approval source that does not " \
                                  "match its assistant tool call"
      end
      return if approval_mirrors?(prepared, source)

      validate_normalizable_source!(state)
      return if prepared_call_from_source?(prepared, source)

      raise ConfigurationError, "session contains prepared approval metadata that does not " \
                                "match its source call"
    end

    def validate_normalizable_source!(state)
      source = state[:source_call]
      return if source && !source.arguments_error? && source.arguments.is_a?(Hash)

      raise ConfigurationError, "session contains an approval source that could not have " \
                                "been normalized"
    end

    def validate_prepared_call!(prepared, assistant)
      return if prepared_call_from_source?(prepared, assistant)

      raise ConfigurationError, "session contains prepared approval metadata that does not " \
                                "match its assistant tool call"
    end

    def validated_persisted_call(call)
      unless call["type"].to_s == "tool_call"
        raise ConfigurationError, "session contains an invalid tool call type"
      end

      problem = required_string_problem(call["id"], "tool call IDs")
      raise ConfigurationError, "session contains #{problem}" if problem

      problem = required_string_problem(call["name"], "tool call names")
      raise ConfigurationError, "session contains #{problem}" if problem

      validate_optional_string!(call["signature"], "tool call signatures")
      validate_optional_string!(call["provider_call_id"], "provider tool call IDs")
      call["id"]
    end

    def validate_optional_string!(value, label)
      return if value.nil?

      problem = required_string_problem(value, label)
      raise ConfigurationError, "session contains #{problem}" if problem
    end

    def required_string_problem(value, label)
      return "#{label} with no value" if value.nil?
      return "#{label} that are not strings" unless value.is_a?(String)
      unless value.encoding == Encoding::UTF_8 && value.valid_encoding?
        return "#{label} that are not valid UTF-8"
      end
      return "#{label} that are blank" if value.match?(/\A[[:space:]]*\z/)

      nil
    end

    def approval_mirrors?(assistant, approval)
      assistant == approval
    end

    def prepared_call_from_source?(prepared, source)
      %w[id name signature provider_call_id].all? do |field|
        persisted_call_field(prepared, field) == persisted_call_field(source, field)
      end
    end

    def persisted_call_field(call, field)
      call[field]
    end

    def replay_from(log)
      compaction = log.reverse_each.find { |entry| entry["type"] == "compaction" }
      from = compaction ? compaction["kept_from"] : 0
      pairs = log.each_with_index.filter_map do |entry, index|
        next unless index >= from && entry["type"] == "message"

        [Message.from_h(entry["message"]), index]
      end
      pairs = heal(pairs, replay_call_states(log, from:))
      compaction ? [[summary_message(compaction["summary"]), nil], *pairs] : pairs
    end

    # Replay only needs occurrence pairing, not the authorization audit. Keep
    # it tolerant enough to render a rejected history while still ensuring a
    # reused call_N cannot borrow an earlier result or approval.
    def replay_call_states(log, from:)
      replay = { active: {}, seen: Set.new, approval_ids: Set.new, states: [], from: }
      log.each_with_index do |entry, index|
        if entry["type"] == "message"
          track_replay_message(entry, index, replay)
        else
          track_replay_control(entry, replay)
        end
      end
      replay.fetch(:states).each do |state|
        next unless state[:ambiguous_approval]
        next unless %i[approval_requested decided].include?(state[:status])

        state[:status] = :interrupted
      end
    end

    def track_replay_message(entry, index, replay)
      role = entry.dig("message", "role").to_s
      if role == "assistant"
        tool_calls_from(entry).each_with_index do |call, position|
          id = call["id"]
          state = { source_index: index, source_position: position, status: :pending,
                    reused: replay.fetch(:seen).include?(id), approval: false }
          replay.fetch(:states) << state if index >= replay.fetch(:from)
          replay.fetch(:active)[id] = state
          replay.fetch(:seen) << id
        end
      elsif role == "tool" &&
            (state = replay.fetch(:active).delete(entry.dig("message", "tool_call_id")))
        state[:status] = :answered
        state[:result_index] = index
      end
    end

    def track_replay_control(entry, replay)
      if entry["type"] == "approval_request"
        id = entry.dig("call", "id")
        return unless (state = replay.fetch(:active)[id])

        state[:status] = :approval_requested
        state[:approval] = true
        state[:ambiguous_approval] = state[:reused] && replay.fetch(:approval_ids).include?(id)
        replay.fetch(:approval_ids) << id
      elsif entry["type"] == "approval_decision"
        state = replay.fetch(:active)[entry["call_id"]]
        state[:status] = :decided if state&.dig(:status) == :approval_requested
      end
    end

    def heal(pairs, states)
      by_source = states.group_by { |state| state[:source_index] }
      by_result = pairs.to_h { |message, index| [index, [message, index]] }
      consumed = states.filter_map { |state| state[:result_index] }.to_set
      pairs.flat_map do |message, index|
        next [] if consumed.include?(index)

        batch = by_source[index]
        next [[message, index]] unless message.assistant? && batch

        [[message, index], *healed_results(message, batch, by_result)]
      end
    end

    def healed_results(message, states, by_result)
      calls = message.tool_calls
      [false, true].flat_map do |approval_phase|
        states.select { |state| state[:approval] == approval_phase }
              .sort_by { |state| state[:source_position] }
              .filter_map do |state|
          if state[:status] == :answered
            by_result.fetch(state[:result_index])
          elsif !approval_phase || state[:status] == :interrupted
            interrupted_pair(calls.fetch(state[:source_position]))
          end
        end
      end
    end

    def interrupted_pair(call)
      [Message.tool(content: INTERRUPTED_RESULT, tool_call_id: call.id,
                    tool_name: call.name, tool_error: true), nil]
    end

    def summary_message(summary)
      Message.user("#{Compaction::SUMMARY_PREFACE}\n\n#{summary}")
    end

    # Each link entry opens its child's log in place, depth first, the way
    # nested lanes opened live. The seen set makes expansion idempotent per
    # child (a repeated or self-referencing link renders but never expands
    # twice), so a hostile log cannot loop this.
    def splice(log, include_children:, prefix:, seen:)
      log.flat_map do |entry|
        rendered = Child.strip_images(entry)
        rendered = rendered.merge("origin" => prefix) if prefix
        next [rendered] unless include_children && expandable?(entry, seen)

        seen << entry["session_id"]
        origin = "#{entry["name"]}##{entry["session_id"][0, 8]}"
        origin = "#{prefix}>#{origin}" if prefix
        child_log = self.class.new(store: @store, id: entry["session_id"]).entries
        [rendered, *splice(child_log, include_children: true, prefix: origin, seen: seen)]
      end
    end

    def expandable?(entry, seen)
      entry["type"] == "subagent" && !seen.include?(entry["session_id"])
    end

    # How a report reads to the model: labeled with the worker's name and
    # fate, so the parent knows exactly who finished and how.
    def report_label(name, status, text)
      case status
      when "done" then "[#{name} finished] #{text}"
      when "failed" then "[#{name} failed] #{text}"
      when "stopped" then "[#{name} was stopped]"
      else "[#{name} ended: #{status}]"
      end
    end

    def decide(call_id, approved:, note:)
      open = open_approvals.find { |approval| approval[:call].id == call_id }
      raise ConfigurationError, "no open approval for #{call_id.inspect}" unless open

      if open[:decision]
        raise ConfigurationError, "approval for #{call_id.inspect} has already been decided"
      end

      entry = { "call_id" => call_id, "approved" => approved }
      entry["note"] = note if note
      append("approval_decision", entry)
    end

    def own_json(value)
      case value
      when Hash then value.to_h { |key, nested| [own_json(key), own_json(nested)] }
      when Array then value.map { |nested| own_json(nested) }
      when String then value.dup
      else value
      end
    end

    def rebuild_call(hash)
      arguments = hash.key?("arguments") ? hash["arguments"] : {}
      ToolCall.new(id: hash["id"], name: hash["name"],
                   arguments:, signature: hash["signature"],
                   arguments_error: hash["arguments_error"],
                   provider_call_id: hash["provider_call_id"])
    end
  end # rubocop:enable Metrics/ClassLength
end
