# frozen_string_literal: true

require_relative "test_helper"

# The compaction gauge: real usage from the last healthy turn plus estimates
# for the tail, and the threshold that triggers a compact.
class TestCompaction < Minitest::Test
  def test_estimate_uses_a_chars_over_four_heuristic
    message = Mistri::Message.user("x" * 400)

    assert_equal 100, Mistri::Compaction.estimate(message)
  end

  def test_context_tokens_prefers_reported_usage_and_estimates_the_tail
    usage = Mistri::Usage.new(input: 900, output: 100)
    history = [Mistri::Message.user("hi"),
               Mistri::Message.assistant(content: "sure", usage: usage, stop_reason: :stop),
               Mistri::Message.user("y" * 400)]

    assert_equal 1100, Mistri::Compaction.context_tokens(history)
  end

  def test_context_tokens_falls_back_to_estimates_without_usage
    history = [Mistri::Message.user("x" * 40), Mistri::Message.user("y" * 40)]

    assert_equal 20, Mistri::Compaction.context_tokens(history)
  end

  def test_an_errored_turn_never_anchors_the_gauge
    bad = Mistri::Message.assistant(content: "boom", stop_reason: :error,
                                    usage: Mistri::Usage.new(input: 999_999))
    history = [Mistri::Message.user("x" * 40), bad]

    assert_operator Mistri::Compaction.context_tokens(history), :<, 100
  end

  def test_needed_only_inside_the_reserve_and_never_without_a_window
    compaction = Mistri::Compaction.new(reserve: 100)

    refute compaction.needed?(899, 1_000)
    assert compaction.needed?(901, 1_000)
    refute compaction.needed?(1_000_000, nil)
  end

  def test_automatic_headroom_covers_full_output_and_framing_slack
    compaction = Mistri::Compaction.new
    boundaries = [["claude-opus-4-8", 867_904],
                  ["claude-haiku-4-5", 131_904],
                  ["gpt-5.5", 917_904],
                  ["gpt-5-nano", 267_904],
                  ["gemini-3.1-pro-preview", 1_032_192]]

    boundaries.each do |model_id, boundary|
      model = Mistri::Models.find(model_id)
      shared_output = Mistri::Models.shared_output(model_id)

      refute compaction.needed?(boundary, model.context_window, max_output: shared_output)
      assert compaction.needed?(boundary + 1, model.context_window, max_output: shared_output)
    end
  end

  def test_explicit_reserve_wins_and_unknown_output_uses_the_legacy_fallback
    explicit = Mistri::Compaction.new(reserve: 100)
    automatic = Mistri::Compaction.new

    refute explicit.needed?(899, 1_000, max_output: 900)
    assert explicit.needed?(901, 1_000, max_output: 900)
    refute automatic.needed?(983_616, 1_000_000)
    assert automatic.needed?(983_617, 1_000_000)
    assert_predicate automatic, :automatic_reserve?
    refute_predicate explicit, :automatic_reserve?
    assert_equal Mistri::Compaction::DEFAULT_RESERVE, automatic.reserve
    assert_equal 100, explicit.reserve
  end

  def test_cache_reads_count_toward_context
    usage = Mistri::Usage.new(input: 10, cache_read: 890, output: 100)
    history = [Mistri::Message.assistant(content: "ok", usage: usage, stop_reason: :stop)]

    assert_equal 1_000, Mistri::Compaction.context_tokens(history)
  end

  def test_session_context_ignores_stale_usage_until_a_fresh_turn_arrives
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "c1", name: "lookup", arguments: {})
    session.append_message(Mistri::Message.user("old request"))
    session.append_message(Mistri::Message.assistant(content: [call], stop_reason: :tool_use,
                                                     usage: Mistri::Usage.new(input: 900,
                                                                              output: 100)))
    session.append_message(Mistri::Message.tool(content: "recent result", tool_call_id: "c1"))
    session.append("compaction", "summary" => "## Goal\nContinue.",
                                 "kept_from" => 1, "tokens_before" => 1_000)

    estimated = Mistri::Compaction.context_tokens(
      session.messages, usage_from: session.messages.length
    )

    assert_equal estimated, session.context_tokens
    assert_operator session.context_tokens, :<, 1_000

    session.append_message(Mistri::Message.assistant(content: "fresh", stop_reason: :stop,
                                                     usage: Mistri::Usage.new(input: 200,
                                                                              output: 20)))

    assert_equal 220, session.context_tokens
  end
end
