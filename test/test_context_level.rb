# frozen_string_literal: true

require_relative "test_helper"

# The context level: the provider's own count wherever one can be had. A turn
# reports it, a compaction stores the count of what it leaves, the turns a
# compaction keeps are sized from reported prompts, and the provider counts a
# request where the estimated part could decide a compaction either way.
class TestContextLevel < Minitest::Test
  class Counting < Mistri::Providers::Fake
    attr_reader :counted

    def initialize(count:, **)
      super(**)
      @count = count
      @counted = []
    end

    def count_tokens(messages:, **)
      @counted << messages.dup
      @count.respond_to?(:call) ? @count.call : @count
    end
  end

  USAGE = Mistri::Usage.new(input: 900, output: 100)

  def test_a_level_says_how_much_of_it_is_estimated
    history = [Mistri::Message.user("hi"),
               Mistri::Message.assistant(content: "sure", usage: USAGE, stop_reason: :stop)]
    reported = Mistri::Compaction.level(history)
    grown = Mistri::Compaction.level(history + [Mistri::Message.user("y" * 400)])
    seeded = Mistri::Compaction.level([Mistri::Message.user("y" * 400)])

    assert_equal [1_000, 0, 1_000], [reported.tokens, reported.estimated, reported.reported]
    assert_equal [1_100, 100, 1_000], [grown.tokens, grown.estimated, grown.reported]
    assert_equal [100, 100, 0], [seeded.tokens, seeded.estimated, seeded.reported]
  end

  def test_a_session_no_provider_has_answered_is_estimated_by_the_rule_of_the_agent_s_provider
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("12345" * 100))
    session.append_message(Mistri::Message.assistant(content: "ab cd " * 100, stop_reason: :stop))
    claude = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-5-5")
    agent = Mistri::Agent.new(provider: claude, session:)

    assert_equal 275, session.context_tokens
    assert_equal 501, session.context_level(provider: :anthropic).tokens
    assert_equal [501, 501], agent.context_usage.values_at(:tokens, :estimated)
    assert_equal [501, 188], session.tail_tokens(provider: :anthropic)
  ensure
    claude&.close
  end

  def test_a_tail_is_the_level_less_the_prompt_a_later_turn_reported
    call = Mistri::ToolCall.new(id: "c1", name: "read", arguments: {})
    history = [
      Mistri::Message.user("abcd"),
      Mistri::Message.assistant(content: [call], stop_reason: :tool_use,
                                usage: Mistri::Usage.new(input: 100, output: 20)),
      Mistri::Message.tool(content: "x" * 400, tool_call_id: "c1"),
      Mistri::Message.assistant(content: "done", stop_reason: :stop,
                                usage: Mistri::Usage.new(input: 250, output: 30)),
      Mistri::Message.user("y" * 40)
    ]

    assert_equal [191, 190, 140, 40, 10], Mistri::Compaction.tail_tokens(history)
    assert_equal [114, 113, 111, 11, 10], Mistri::Compaction.tail_tokens(history, usage_from: 5)
    assert_equal [], Mistri::Compaction.tail_tokens([])
  end

  def test_a_tail_never_exceeds_the_level_when_an_estimate_overshoots_a_reported_prompt
    history = [Mistri::Message.user("x" * 4_000),
               Mistri::Message.assistant(content: "ok", stop_reason: :stop,
                                         usage: Mistri::Usage.new(input: 50, output: 5))]

    assert_equal [55, 5], Mistri::Compaction.tail_tokens(history)
  end

  def test_a_compaction_keeps_the_turns_the_provider_counted_as_recent
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    [["q1", 10, 5], ["q2", 5_000, 100], ["q3", 5_200, 50]].each do |question, input, output|
      session.append_message(Mistri::Message.user(question))
      session.append_message(Mistri::Message.assistant(
                               content: "ok", stop_reason: :stop,
                               usage: Mistri::Usage.new(input:, output:)
                             ))
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])

    Mistri::Compactor.call(session:, provider:, settings: Mistri::Compaction.new(keep_recent: 200))

    assert_equal 4, session.last_compaction["kept_from"]
    assert_equal %w[q3 ok], session.messages.drop(1).map(&:text)
  end

  def test_a_compaction_stores_the_count_of_what_it_leaves_and_the_level_reads_it
    session = seeded_session
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    left = nil

    result = Mistri::Compactor.call(session:, provider:,
                                    settings: Mistri::Compaction.new(keep_recent: 10),
                                    count: lambda { |messages|
                                      left = messages
                                      321
                                    })

    assert_equal session.messages, left
    assert_equal 321, session.last_compaction["tokens_after"]
    assert_equal 321, result[:tokens_after]
    assert_equal [321, 0], level_of(session)

    session.append_message(Mistri::Message.user("y" * 400))

    assert_equal [421, 100], level_of(session)

    session.append_message(Mistri::Message.assistant(content: "fresh", stop_reason: :stop,
                                                     usage: Mistri::Usage.new(input: 700,
                                                                              output: 20)))

    assert_equal [720, 0], level_of(session)
  end

  def test_a_compaction_whose_count_cannot_be_had_leaves_the_level_estimated
    [nil, ->(_) {}].each do |count|
      session = seeded_session
      provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])

      Mistri::Compactor.call(session:, provider:, count:,
                             settings: Mistri::Compaction.new(keep_recent: 10))

      refute session.last_compaction.key?("tokens_after")
      assert_equal session.context_tokens, session.context_level.estimated
    end
  end

  def test_a_level_over_the_threshold_by_its_reported_part_compacts_with_no_count_first
    provider = counting(1, turns: [{ text: "first", usage: USAGE }, { text: "Summary." },
                                   { text: "second" }])
    agent = agent_with(provider, window: 1_000, reserve: 100)

    agent.run("q1 " * 20)
    agent.run("q2")

    refute_nil agent.session.last_compaction
    assert_equal 1, provider.counted.length, "only what the compaction left was counted"
    assert provider.counted.first.first.text.start_with?(Mistri::Compaction::SUMMARY_PREFACE)
    assert_equal 1, agent.session.last_compaction["tokens_after"]
  end

  def test_the_provider_counts_where_the_estimated_part_could_decide
    over = counting(-> { 1_150 }, turns: [{ text: "first", usage: USAGE }, { text: "Summary." },
                                          { text: "second" }])
    under = counting(1_080, turns: [{ text: "first", usage: USAGE }, { text: "second" }])
    [over, under].each do |provider|
      agent = agent_with(provider, window: 1_200, reserve: 100)
      agent.run("q1 " * 20)
      agent.run("x" * 240)
    end

    assert_equal 2, over.counted.length
    assert_equal "x" * 240, over.counted.first.last.text
    refute_nil over.requests.last[:messages].first.text[Mistri::Compaction::SUMMARY_PREFACE]
    assert_equal 1, under.counted.length
    assert_equal ["q1 " * 20, "first", "x" * 240], under.requests.last[:messages].map(&:text)
  end

  def test_no_count_is_asked_where_the_estimate_cannot_reach_the_threshold
    provider = counting(5_000, turns: [{ text: "first", usage: USAGE }, { text: "second" }])
    agent = agent_with(provider, window: 1_200, reserve: 100)

    agent.run("q1 " * 20)
    agent.run("x" * 200)

    assert_empty provider.counted
    assert_nil agent.session.last_compaction
  end

  def test_the_estimate_decides_when_the_count_cannot_be_had
    failing = counting(-> { raise Mistri::ProviderError, "no count" },
                       turns: [{ text: "first", usage: USAGE }, { text: "second" }])
    plain = Mistri::Providers::Fake.new(turns: [{ text: "first", usage: USAGE },
                                                { text: "second" }])
    [failing, plain].each do |provider|
      agent = agent_with(provider, window: 1_200, reserve: 100)
      agent.run("q1 " * 20)

      assert_predicate agent.run("x" * 240), :completed?
      assert_nil agent.session.last_compaction
    end
  end

  def test_context_usage_says_what_is_estimated_and_counts_on_request
    provider = counting(1_234, turns: [{ text: "first", usage: USAGE }])
    agent = agent_with(provider, window: 10_000, reserve: 100)
    agent.run("q1")

    assert_equal({ tokens: 1_000, window: 10_000, fraction: 0.1, estimated: 0 },
                 agent.context_usage)

    agent.session.append_message(Mistri::Message.user("y" * 400))

    assert_equal({ tokens: 1_100, window: 10_000, fraction: 0.11, estimated: 100 },
                 agent.context_usage)
    assert_equal({ tokens: 1_234, window: 10_000, fraction: 0.123, estimated: 0 },
                 agent.context_usage(count: true))
  end

  def test_a_count_is_asked_for_the_history_as_the_provider_receives_it
    provider = Class.new(Counting) { def system_messages? = false }.new(count: 9, turns: [])
    agent = agent_with(provider, window: 10_000, reserve: 100)
    agent.session.append_message(Mistri::Message.user("q1"))
    agent.session.append_message(Mistri::Message.reminder("note", "Mind the gap."))

    assert_equal 9, agent.context_usage(count: true)[:tokens]
    assert(provider.counted.last.none?(&:reminder))
    assert_includes provider.counted.last.map(&:text).join, "Mind the gap."
  end

  def test_context_usage_keeps_the_estimate_when_the_provider_cannot_count
    provider = Mistri::Providers::Fake.new(turns: [{ text: "first", usage: USAGE }])
    agent = agent_with(provider, window: 10_000, reserve: 100)
    agent.run("q1")
    agent.session.append_message(Mistri::Message.user("y" * 400))

    assert_equal 100, agent.context_usage(count: true)[:estimated]
  end

  private

  def counting(count, turns:) = Counting.new(count:, turns:)

  def level_of(session) = session.context_level.to_h.values_at(:tokens, :estimated)

  def agent_with(provider, window:, reserve:)
    Mistri::Agent.new(provider:,
                      compaction: Mistri::Compaction.new(window:, reserve:, keep_recent: 10))
  end

  def seeded_session
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("q1 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a1 " * 200, stop_reason: :stop))
    session.append_message(Mistri::Message.user("q2"))
    session.append_message(Mistri::Message.assistant(content: "a2", stop_reason: :stop))
    session
  end
end
