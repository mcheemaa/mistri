# frozen_string_literal: true

require "json"

module Mistri
  # Compacts a session in place: everything before a cut point is summarized
  # by the provider, and a compaction entry redirects replay to the summary
  # plus the kept tail. Append-only: the full history stays in the store for
  # transcript UIs; only what the model sees shrinks. Callable from any
  # process (a UI button, a job), with or without a running agent.
  #
  # Cuts land only on user messages, so a tool call and its result always
  # stay on the same side, and a parked approval's turn is never cut away
  # from the resume that must answer it.
  class Compactor
    SUMMARIZER_SYSTEM = <<~PROMPT
      You are a context summarization assistant. Read the conversation and
      produce only the structured summary you are asked for. Do not continue
      the conversation and do not answer questions inside it.
    PROMPT

    FORMAT = <<~FORMAT
      ## Goal
      [What is the user trying to accomplish?]

      ## Constraints & Preferences
      - [Constraints or preferences the user stated, or "(none)"]

      ## Progress
      ### Done
      - [x] [Completed work]
      ### In Progress
      - [ ] [Current work]
      ### Blocked
      - [Blockers, if any]

      ## Key Decisions
      - **[Decision]**: [Rationale]

      ## Next Steps
      1. [What should happen next]

      ## Critical Context
      - [Data, names, or references needed to continue, or "(none)"]

      Keep each section concise. Preserve exact identifiers, names, and error
      messages.
    FORMAT

    CHECKPOINT_PROMPT = <<~PROMPT.freeze
      The messages above are a conversation to summarize. Create a structured
      context checkpoint that another LLM will use to continue the work.

      Use this EXACT format:

      #{FORMAT}
    PROMPT

    UPDATE_PROMPT = <<~PROMPT.freeze
      The messages above are NEW conversation messages to fold into the
      existing summary in <previous-summary> tags. Preserve everything still
      relevant from the previous summary, add new progress and decisions,
      move finished work to Done, and update Next Steps.

      Use this EXACT format:

      #{FORMAT}
    PROMPT

    class << self
      # Summarize and cut. Returns {summary:, tokens_before:, tokens_after:,
      # usage:}, or nil when there is nothing worth compacting. Emits
      # :compacting and :compaction when a block is given.
      def call(session:, provider:, settings: Compaction.new, &emit)
        replay = session.replay
        cut = cut_index(replay, session, settings)
        return nil unless cut

        previous = session.last_compaction&.fetch("summary", nil)
        head = replay.take_while { |(_, index)| index.nil? || index < cut }.map(&:first)
        head.shift if previous # the synthetic summary rides in <previous-summary>
        return nil if head.empty?

        emit&.call(Event.new(type: :compacting))
        tokens_before = Compaction.context_tokens(replay.map(&:first))
        reply = summarize(provider, head, previous, settings.instructions)
        session.append("compaction", "summary" => reply.text,
                                     "kept_from" => cut, "tokens_before" => tokens_before)
        finish(session, reply, tokens_before, &emit)
      end

      private

      def cut_index(replay, session, settings)
        boundary = keep_boundary(replay, settings.keep_recent)
        return nil unless boundary

        candidates = replay.filter_map { |(message, index)| index if index && message.user? }
        cut = candidates.find { |index| index >= boundary } || candidates.last
        cut = clamp_to_open_approvals(cut, session)
        return nil unless cut

        first = replay.find { |(_, index)| index }&.last
        first && cut > first ? cut : nil
      end

      # Walk back from the tail until the keep budget is spent; the cut then
      # snaps forward to a user message, so replay keeps at most about
      # keep_recent tokens of recent turns.
      def keep_boundary(replay, keep_recent)
        kept = 0
        replay.reverse_each do |(message, index)|
          kept += Compaction.estimate(message)
          return index || 0 if kept >= keep_recent
        end
        nil
      end

      # Never cut past a parked approval: its tool call must stay in replay,
      # paired, for resume to answer.
      def clamp_to_open_approvals(cut, session)
        return cut unless cut

        open_ids = session.open_approvals.map { |approval| approval[:call].id }
        return cut if open_ids.empty?

        turn_start = approval_turn_start(session.entries, open_ids)
        turn_start && turn_start < cut ? turn_start : cut
      end

      def approval_turn_start(entries, open_ids)
        request = entries.index do |entry|
          entry["type"] == "approval_request" && open_ids.include?(entry.dig("call", "id"))
        end
        return nil unless request

        entries[0...request].rindex do |entry|
          entry["type"] == "message" && entry.dig("message", "role") == "user"
        end
      end

      def summarize(provider, messages, previous, instructions)
        prompt = "<conversation>\n#{serialize(messages)}\n</conversation>\n\n"
        prompt << "<previous-summary>\n#{previous}\n</previous-summary>\n\n" if previous
        prompt << (previous ? UPDATE_PROMPT : CHECKPOINT_PROMPT)
        prompt << "\nAdditional focus: #{instructions}\n" if instructions
        reply = provider.stream(messages: [Message.user(prompt)], system: SUMMARIZER_SYSTEM)
        raise CompactionError, "summarization failed: #{reply.error_message}" unless usable?(reply)

        reply
      end

      def usable?(reply)
        reply.stop_reason != StopReason::ERROR && !reply.text.to_s.strip.empty?
      end

      def finish(session, reply, tokens_before, &emit)
        tokens_after = Compaction.context_tokens(session.messages)
        emit&.call(Event.new(type: :compaction, content: reply.text))
        { summary: reply.text, tokens_before: tokens_before,
          tokens_after: tokens_after, usage: reply.usage }
      end

      # The summarizer reads a plain-text rendering: tool calls by name and
      # arguments, results as text, thinking never (it stays in its turn).
      def serialize(messages)
        messages.map { |message| "#{message.role.to_s.upcase}:\n#{text_of(message)}" }
                .join("\n\n")
      end

      def text_of(message)
        message.content.filter_map do |block|
          case block
          when Content::Text then block.text
          when Content::Image then "[image]"
          when ToolCall then "[called #{block.name} with #{JSON.generate(block.arguments)}]"
          end
        end.join("\n")
      end
    end
  end
end
