# frozen_string_literal: true

require_relative "test_helper"

# The threshold a host sets: a level in tokens or a share of the window where
# a compaction starts, what context_usage and the events say about it, the
# room a compaction leaves under it, and what a worker takes from its parent.
class TestCompactionThreshold < Minitest::Test
  USAGE = Mistri::Usage.new(input: 900, output: 100)

  def test_a_threshold_is_tokens_or_a_share_and_the_reserve_stays_under_it_as_the_net
    tokens = Mistri::Compaction.new(threshold: 40_000)
    share = Mistri::Compaction.new(threshold: 0.5)
    whole = Mistri::Compaction.new(threshold: 1.0)

    assert_equal 40_000, tokens.threshold_tokens(1_000_000)
    assert_equal 40_000, tokens.threshold_tokens(nil)
    assert_equal 33_616, tokens.threshold_tokens(50_000)
    assert_equal 500_000, share.threshold_tokens(1_000_000)
    assert_nil share.threshold_tokens(nil)
    assert_equal 983_616, whole.threshold_tokens(1_000_000)
    assert_equal 983_616, Mistri::Compaction.new.threshold_tokens(1_000_000)
    assert tokens.needed?(40_001, nil)
    refute tokens.needed?(40_000, nil)
  end

  def test_a_threshold_that_is_neither_is_refused
    [0, -5, 0.0, 1.5, "40000", true].each do |value|
      error = assert_raises(ArgumentError) { Mistri::Compaction.new(threshold: value) }

      assert_match(/threshold must be a positive Integer of tokens or a Float share/, error.message)
    end
  end

  def test_the_kept_turns_take_at_most_half_of_the_room_above_the_fixed_part
    settings = Mistri::Compaction.new(keep_recent: 20_000)

    assert_equal 20_000, settings.keep_within(nil, 6_000)
    assert_equal 20_000, settings.keep_within(900_000, 6_000)
    assert_equal 17_000, settings.keep_within(40_000, 6_000)
    assert_equal 0, settings.keep_within(40_000, 45_000)
  end

  def test_a_compaction_at_a_low_threshold_leaves_room_under_it
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    10.times do |turn|
      session.append_message(Mistri::Message.user("q#{turn}"))
      session.append_message(Mistri::Message.assistant(
                               content: "ok", stop_reason: :stop,
                               usage: Mistri::Usage.new(input: 1_000 + (turn * 400), output: 395)
                             ))
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    provider.define_singleton_method(:model) { "claude-opus-5-5" }

    Mistri::Compactor.call(session:, provider:,
                           settings: Mistri::Compaction.new(threshold: 4_000, keep_recent: 3_000))
    kept = session.messages.drop(1)

    assert_equal 6, kept.length, "half of the 3,000 above the fixed 1,000 holds three turns of 400"
    assert_equal "q7", kept.first.text
  end

  def test_a_share_of_a_window_the_host_gave_sizes_the_kept_turns
    session = seeded_session
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    settings = Mistri::Compaction.new(window: 400, threshold: 0.5, keep_recent: 1_000)

    Mistri::Compactor.call(session:, provider:, settings:)

    assert_equal %w[q2 a2], session.messages.drop(1).map(&:text)
    refute session.last_compaction.key?("tokens_after")
  end

  def test_a_checkpoint_written_with_no_details_holds_none
    session = seeded_session

    session.checkpoint(summary: "Earlier.", kept_from: 2)

    assert_equal %w[at carried kept_from summary type], session.last_compaction.keys.sort
  end

  def test_context_usage_gives_the_threshold_and_what_remains
    provider = Mistri::Providers::Fake.new(turns: [{ text: "first", usage: USAGE }])
    agent = Mistri::Agent.new(provider:, compaction: Mistri::Compaction.new(threshold: 4_000))
    off = Mistri::Agent.new(provider: Mistri::Providers::Fake.new, compaction: false)
    agent.run("q1")

    assert_equal [1_000, 4_000, 3_000],
                 agent.context_usage.values_at(:tokens, :threshold, :remaining)
    assert_equal [nil, nil], off.context_usage.values_at(:threshold, :remaining)

    agent.session.append_message(Mistri::Message.user("y" * 16_000))

    assert_equal 0, agent.context_usage[:remaining]
  end

  def test_a_compaction_on_demand_takes_words_for_that_one_time
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    agent = Mistri::Agent.new(provider:, session: seeded_session,
                              compaction: Mistri::Compaction.new(keep_recent: 10,
                                                                 instructions: "Keep dates."))

    agent.compact(instructions: "Keep every amount.")
    prompt = provider.requests.first[:messages].last.text

    assert prompt.end_with?("\nAdditional focus: Keep every amount.\n")
    refute_includes prompt, "Keep dates."
  end

  def test_the_events_and_the_entry_say_what_started_a_compaction_its_sizes_and_its_time
    provider = Mistri::Providers::Fake.new(turns: [{ text: "first " * 100, usage: USAGE },
                                                   { text: "Summary." }, { text: "second" }])
    agent = Mistri::Agent.new(provider:,
                              compaction: Mistri::Compaction.new(threshold: 900, keep_recent: 10))
    events = []
    agent.run("q1 " * 20)
    agent.run("q2") { |event| events << event if event.type.to_s.start_with?("compact") }
    compacting, compaction = events
    entry = agent.session.last_compaction

    assert_equal %i[compacting compaction], events.map(&:type)
    assert_equal [:automatic, 1_001, nil],
                 compacting.to_h.values_at(:reason, :tokens_before, :tokens_after)
    assert_equal [:automatic, 1_001], compaction.to_h.values_at(:reason, :tokens_before)
    assert_operator compaction.tokens_after, :<, 1_001
    assert_kind_of Float, compaction.duration
    assert_equal ["automatic", 1_001], entry.values_at("trigger", "tokens_before")
    assert_kind_of Float, entry["duration"]
  end

  def test_a_failed_compaction_says_what_started_it_and_how_long_it_took
    provider = Mistri::Providers::Fake.new(turns: [{ text: "" }])
    agent = Mistri::Agent.new(provider:, session: seeded_session,
                              compaction: Mistri::Compaction.new(keep_recent: 10))
    events = []

    assert_raises(Mistri::CompactionError) { agent.compact { |event| events << event } }
    failed = events.last
    entry = agent.session.entries.last

    assert_equal %i[compaction_failed manual], [failed.type, failed.reason]
    assert_kind_of Float, failed.duration
    assert_equal "manual", entry["trigger"]
    assert_kind_of Float, entry["duration"]
  end

  def test_no_automatic_compaction_starts_when_nothing_was_stored_since_the_last_one
    session = seeded_session
    summarizer = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    settings = Mistri::Compaction.new(threshold: 1, keep_recent: 1)
    Mistri::Compactor.call(session:, provider: summarizer, settings:)
    provider = Mistri::Providers::Fake.new(turns: [{ text: "done" }])
    agent = Mistri::Agent.new(provider:, session:, compaction: settings)

    refute_predicate session, :grown_since_compaction?
    assert_predicate Mistri::Session.new(store: Mistri::Stores::Memory.new),
                     :grown_since_compaction?
    assert_predicate agent.resume, :completed?
    assert_equal 1, provider.requests.length
    assert_equal(1, session.entries.count { |entry| entry["type"] == "compaction" })
  end

  def test_a_worker_with_no_setting_of_its_own_takes_the_threshold_of_its_parent
    parent = Mistri::Compaction.new(threshold: 0.5, keep_recent: 5_000)
    context = Mistri::ToolContext.new(compaction: parent)
    own = Mistri::Compaction.new(threshold: 30_000)
    inherit = ->(options, from) { Mistri::SubAgent.send(:with_parent_threshold, options, from) }

    taken = inherit.call({ budget: nil }, context)

    assert_in_delta 0.5, taken[:compaction].threshold
    assert_equal Mistri::Compaction::DEFAULT_KEEP_RECENT, taken[:compaction].keep_recent
    assert_same own, inherit.call({ compaction: own }, context)[:compaction]
    assert_equal({}, inherit.call({}, Mistri::ToolContext.new))
    assert_equal({}, inherit.call({}, Mistri::ToolContext.new(compaction: Mistri::Compaction.new)))
  end

  def test_a_tool_reads_the_compaction_setting_of_its_agent
    seen = nil
    tool = Mistri::Tool.define("peek", "Peeks.") do |_args, context|
      seen = context.compaction
      "ok"
    end
    settings = Mistri::Compaction.new(threshold: 40_000)
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: [{ name: "peek" }] },
                                                   { text: "done" }])

    Mistri::Agent.new(provider:, tools: [tool], compaction: settings).run("go")

    assert_same settings, seen
  end

  private

  def seeded_session
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("q1 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a1 " * 200, stop_reason: :stop))
    session.append_message(Mistri::Message.user("q2"))
    session.append_message(Mistri::Message.assistant(content: "a2", stop_reason: :stop))
    session
  end
end
