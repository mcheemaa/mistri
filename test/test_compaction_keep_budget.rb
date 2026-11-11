# frozen_string_literal: true

require_relative "test_helper"

# How much of the recent tail a compaction keeps: the keep budget is counted
# back from the end over the messages the log holds.
class TestCompactionKeepBudget < Minitest::Test
  def setup
    @session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
  end

  def test_an_interrupted_call_at_the_tail_does_not_stop_a_compaction
    @session.append_message(Mistri::Message.user("old question " * 50))
    @session.append_message(Mistri::Message.assistant(content: "old answer " * 50,
                                                      stop_reason: :stop))
    @session.append_message(Mistri::Message.user("paint it"))
    lost = Mistri::ToolCall.new(id: "lost", name: "paint", arguments: {})
    @session.append_message(Mistri::Message.assistant(tool_calls: [lost], stop_reason: :tool_use))

    result = compact(keep_recent: 1)

    refute_nil result, "the compaction was declined"
    assert_equal 3, @session.last_compaction["kept_from"]
    assert_equal %i[user assistant tool], @session.messages.map(&:role)
  end

  def test_a_kept_tail_within_the_keep_budget_is_left_whole
    @session.append_message(Mistri::Message.user("old question"))
    tail = [Mistri::Message.assistant(content: "kept answer", stop_reason: :stop),
            Mistri::Message.user("next question"),
            Mistri::Message.assistant(content: "next answer", stop_reason: :stop)]
    tail.each { |message| @session.append_message(message) }
    @session.append("compaction", "summary" => "Earlier.", "kept_from" => 1)
    budget = tail.sum { |message| Mistri::Compaction.estimate(message) } + 1

    assert_nil compact(keep_recent: budget)
    assert_equal 1, @session.last_compaction["kept_from"]
  end

  private

  def compact(keep_recent:)
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    Mistri::Compactor.call(session: @session, provider:,
                           settings: Mistri::Compaction.new(keep_recent:))
  end
end
