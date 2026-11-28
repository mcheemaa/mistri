# frozen_string_literal: true

require_relative "test_helper"

# The text a summarizer reads when it cannot be given the conversation
# itself: a tool result is whole when the text fits the summarizer's window,
# and the longest results are cut first when it does not.
class TestCompactionText < Minitest::Test
  FLOOR = Mistri::Compactor::TOOL_RESULT_MAX_CHARS
  CUT = "truncated; original length"

  # A fallback the catalog knows, with the window the catalog gives it.
  class Known < Mistri::Providers::Fake
    def model = "claude-haiku-5-5"
  end

  def test_a_long_result_is_whole_when_the_text_fits_the_window
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    session = history(6_000)

    Mistri::Compactor.call(session:, provider:, settings: settings(window: 40_000))
    text = provider.requests.first[:messages].first.text

    assert_includes text, "MIDDLE_0"
    refute_includes text, CUT
  end

  def test_the_longest_results_are_cut_first_to_one_length_that_fits
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    session = history(3_000, 9_000, 30_000)

    Mistri::Compactor.call(session:, provider:, settings: settings(window: 6_000))
    text = provider.requests.first[:messages].first.text
    kept = text.scan(/START_\d.*?END_\d/m).map(&:length)

    assert_equal 3_000, kept.first
    assert_operator kept[1], :<, 9_000
    assert_in_delta kept[1], kept[2], 1
    assert_includes text, "MIDDLE_0"
    refute_includes text, "MIDDLE_2"
    assert_operator text.length / 4.0, :<=, 5_000
    assert_operator text.length / 4.0, :>, 4_500
  end

  def test_no_result_is_cut_under_the_length_of_no_known_window
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    session = history(3_000, 9_000)

    Mistri::Compactor.call(session:, provider:, settings: settings(window: 1_100))
    text = provider.requests.first[:messages].first.text

    assert_equal [FLOOR, FLOOR], text.scan(/START_\d.*?END_\d/m).map(&:length)
  end

  def test_a_fallback_reads_a_text_fitted_to_its_own_window
    provider = Mistri::Providers::Fake.new(turns: [{ error: "overloaded" }])
    fallback = Known.new(turns: [{ text: "Summary." }])
    session = history(9_000)

    Mistri::Compactor.call(session:, provider:, settings: settings(window: 3_100, fallback:))
    own, other = [provider, fallback].map { |asked| asked.requests.first[:messages].first.text }

    assert_includes own, CUT
    assert_includes other, "MIDDLE_0"
    refute_includes other, CUT
  end

  def test_the_room_holds_the_previous_summary_and_the_focus_too
    provider = Mistri::Providers::Fake.new(turns: [{ text: "First. #{"word " * 1_500}" },
                                                   { text: "Second." }])
    session = history(3_000)
    Mistri::Compactor.call(session:, provider:, settings: settings(window: 40_000))
    grow(session, 0, 9_000)
    grow(session, 1, 20)

    Mistri::Compactor.call(session:, provider:, instructions: "Keep the ids.",
                           settings: settings(window: 5_000))
    text = provider.requests.last[:messages].first.text

    assert_includes text, "<previous-summary>\nFirst."
    assert text.end_with?("Additional focus: Keep the ids.\n")
    assert_includes text, CUT
    assert_operator text.length / 4.0, :<=, 4_000
  end

  private

  def settings(**) = Mistri::Compaction.new(keep_recent: 10, max_tokens: 1_000, reserve: 1_000, **)

  def history(*lengths)
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    lengths.each_with_index { |length, index| grow(session, index, length) }
    grow(session, lengths.length, 20)
    session
  end

  def grow(session, index, length)
    call = Mistri::ToolCall.new(id: "c#{session.entries.length}", name: "inspect", arguments: {})
    half = (length - 20) / 2
    output = "START_#{index}#{"x" * half}MIDDLE_#{index}#{"y" * (length - half - 20)}END_#{index}"
    session.append_message(Mistri::Message.user("inspect part #{index}"))
    session.append_message(Mistri::Message.assistant(content: [call], stop_reason: :tool_use))
    session.append_message(Mistri::Message.tool(content: output, tool_call_id: call.id,
                                                tool_name: "inspect"))
    session.append_message(Mistri::Message.assistant(content: "ready", stop_reason: :stop))
  end
end
