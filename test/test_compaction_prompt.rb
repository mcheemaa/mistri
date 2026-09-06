# frozen_string_literal: true

require_relative "test_helper"

# The handoff prompt: what the summarizer is told, what of its reply is kept,
# and how replay introduces the result.
class TestCompactionPrompt < Minitest::Test
  SETTINGS = Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 10)

  def test_the_checkpoint_prompt_asks_for_the_seven_sections_of_a_handoff
    prompt = Mistri::Compactor::CHECKPOINT_PROMPT

    headings = ["Goal and requests", "Constraints and preferences", "Facts and references",
                "Decisions", "Progress", "Open failures", "Current work and next step"]

    headings.each_with_index { |heading, i| assert_includes prompt, "#{i + 1}. #{heading}" }
    assert_includes prompt, "Only USER: turns are the user"
    assert_includes prompt, "[tool result truncated"
    assert_includes prompt, "quoted in the user's own words"
    assert_includes prompt, "current value only"
    assert_includes prompt, "One line per step of work"
    assert_includes prompt, "do not count them"
    assert_includes prompt, "under 1,000 words"
    assert_includes Mistri::Compactor::SUMMARIZER_SYSTEM, "the record, not a reviewer"
    assert_includes Mistri::Compactor::SUMMARIZER_SYSTEM, "qualify it"
    assert_includes Mistri::Compactor::SUMMARIZER_SYSTEM, "do not call tools"
  end

  def test_the_update_prompt_carries_the_fold_rules
    prompt = Mistri::Compactor::UPDATE_PROMPT

    assert_includes prompt, "<previous-summary>"
    assert_includes prompt, "Only USER: turns are the user"
    assert_includes prompt, "7. Current work and next step"
    assert_includes prompt, "Never list two versions as if both applied"
    assert_includes prompt, "drop failures that\n  were resolved"
    assert_includes prompt, "keep its lines verbatim"
    assert_includes prompt, "grows only by what the new messages add"
  end

  def test_the_reply_is_the_summary_and_replay_introduces_it
    reply = "1. Goal and requests\nShip FIN-2831.\n\n7. Current work and next step\nRun it.\n"
    provider = Mistri::Providers::Fake.new(turns: [{ text: reply }])
    session = history
    events = []

    result = Mistri::Compactor.call(session:, provider:, settings: SETTINGS) { |e| events << e }

    assert_equal reply.strip, result[:summary]
    assert_equal reply.strip, session.last_compaction.fetch("summary")
    assert_equal reply.strip, events.last.content
    assert_equal "fake-1", events.last.message.model
    assert session.messages.first.text.start_with?(Mistri::Compaction::SUMMARY_PREFACE)
    assert_includes session.messages.first.text, "Ship FIN-2831."
  end

  private

  def history
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("Original export rules. " * 80))
    session.append_message(Mistri::Message.assistant(content: "Source inspected. " * 80,
                                                     stop_reason: :stop))
    session.append_message(Mistri::Message.user("Retain this follow-up. " * 80))
    session
  end
end
