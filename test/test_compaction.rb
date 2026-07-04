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

  def test_cache_reads_count_toward_context
    usage = Mistri::Usage.new(input: 10, cache_read: 890, output: 100)
    history = [Mistri::Message.assistant(content: "ok", usage: usage, stop_reason: :stop)]

    assert_equal 1_000, Mistri::Compaction.context_tokens(history)
  end
end
