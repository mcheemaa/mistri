# frozen_string_literal: true

require_relative "test_helper"

# A provider's own compaction: the provider writes the summary, its block is
# stored as it came and sent back first, the kept turns keep their thinking,
# and the gem's own summary follows when the provider's cannot be had.
class TestNativeCompaction < Minitest::Test
  BLOCK = { "type" => "compaction", "content" => "1. Goal and requests\nKeep the ledger.",
            "signature" => "sig-1" }.freeze

  # A provider that compacts itself: a request with compaction: is answered
  # with the block, or with what the test scripted in its place.
  class Compacting < Mistri::Providers::Fake
    attr_reader :compactions

    def initialize(native: nil, **)
      super(**)
      @native = native
      @compactions = []
    end

    def compacts? = true

    def stream(messages: [], **options, &)
      return super unless options[:compaction]

      @compactions << { messages: messages.dup, options: }
      @native || Mistri::Message.assistant(
        content: [Mistri::Content::Compaction.new(provider: :fake, data: BLOCK,
                                                  text: BLOCK["content"])],
        stop_reason: :stop, model: model, provider: :fake,
        usage: Mistri::Usage.new(input: 40, output: 9)
      )
    end
  end

  def test_the_provider_writes_the_summary_from_the_request_of_the_turn_and_the_gem_s_prompt
    provider = Compacting.new
    agent = Mistri::Agent.new(provider:, session: seeded_session, system: "Be exact.",
                              compaction: settings(instructions: "Keep dates."))
    events = []

    result = agent.compact { |event| events << event }
    asked = provider.compactions.first
    entry = agent.session.last_compaction

    assert_equal ["q1 " * 50, "a1 " * 200], asked[:messages].map(&:text)
    assert_equal "Be exact.", asked[:options][:system]
    assert_equal "#{Mistri::Compactor::CLOSING_CHECKPOINT_PROMPT}\nAdditional focus: Keep dates.\n",
                 asked[:options][:compaction][:instructions]
    assert_empty provider.requests, "the gem's own summary was not asked for"
    assert_equal BLOCK["content"], result[:summary]
    assert_equal [BLOCK, "fake", BLOCK["content"]], entry.values_at("block", "provider", "summary")
    assert_equal [:native, nil], events.last.to_h.values_at(:status, :error_message)
    assert_equal [40, 9], [result[:usage].input, result[:usage].output]
  end

  def test_replay_begins_with_the_block_and_the_kept_turns_follow_it
    agent = Mistri::Agent.new(provider: Compacting.new, session: seeded_session,
                              compaction: settings)

    agent.compact
    first, *kept = agent.session.messages

    assert_predicate first, :assistant?
    assert_equal [Mistri::Content::Compaction.new(provider: :fake, data: BLOCK,
                                                  text: BLOCK["content"])], first.content
    assert_equal %w[q2 a2], kept.map(&:text)
  end

  def test_kept_turns_keep_their_thinking_after_a_provider_s_compaction_and_not_after_the_gem_s
    kept = lambda do |native|
      session = seeded_session(thinking: true)
      provider = Compacting.new(turns: [{ text: "Summary." }])
      Mistri::Agent.new(provider:, session:, compaction: settings(native:)).compact
      session.messages.last.content.map(&:type)
    end

    assert_equal %i[thinking text], kept.call(true)
    assert_equal %i[text], kept.call(false)
  end

  def test_a_host_can_ask_for_the_gem_s_own_summary
    provider = Compacting.new(turns: [{ text: "Own summary." }])
    agent = Mistri::Agent.new(provider:, session: seeded_session,
                              compaction: settings(native: false))
    events = []

    agent.compact { |event| events << event }

    assert_empty provider.compactions
    assert_equal "Own summary.", agent.session.last_compaction["summary"]
    refute agent.session.last_compaction.key?("block")
    assert_equal [:own, nil], events.last.to_h.values_at(:status, :error_message)
  end

  def test_the_gem_s_own_summary_follows_when_the_provider_returns_none
    none = Mistri::Message.assistant(content: [], stop_reason: :length, model: "fake-1",
                                     usage: Mistri::Usage.new(input: 40, output: 9))
    provider = Compacting.new(native: none, turns: [{ text: "Own summary." }])
    agent = Mistri::Agent.new(provider:, session: seeded_session, compaction: settings)
    events = []

    agent.compact { |event| events << event }
    entry = agent.session.last_compaction

    assert_equal 1, provider.compactions.length
    assert_equal 1, provider.requests.length
    assert_equal "Own summary.", entry["summary"]
    assert_equal "unexpected stop reason: :length", entry["fallback_reason"]
    assert_equal [:own, "unexpected stop reason: :length"],
                 events.last.to_h.values_at(:status, :error_message)
  end

  def test_a_compaction_outside_an_agent_and_a_provider_that_does_not_compact_use_the_gem_s_own
    outside = Compacting.new(turns: [{ text: "Text summary." }])
    plain = Mistri::Providers::Fake.new(turns: [{ text: "Closing summary." }])

    Mistri::Compactor.call(session: seeded_session, provider: outside, settings:)
    Mistri::Agent.new(provider: plain, session: seeded_session, compaction: settings).compact

    assert_empty outside.compactions
    assert_includes outside.requests.first[:messages].first.text, "<conversation>"
    assert_equal "compaction", plain.requests.first[:messages].last.reminder
  end

  def test_a_second_compaction_is_asked_to_fold_the_first_block
    provider = Compacting.new
    session = seeded_session
    agent = Mistri::Agent.new(provider:, session:, compaction: settings)

    agent.compact
    session.append_message(Mistri::Message.user("q3 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a3", stop_reason: :stop))
    agent.compact
    again = provider.compactions.last

    assert_equal :compaction, again[:messages].first.content.first.type
    assert_equal Mistri::Compactor::CLOSING_UPDATE_PROMPT,
                 again[:options][:compaction][:instructions]
  end

  def test_the_note_about_tools_loaded_before_follows_the_kept_turns
    session = seeded_session
    session.append("compaction", "summary" => "S", "kept_from" => 0,
                                 "carried" => { "loaded" => ["read_gauge"] })
    session.append_message(Mistri::Message.user("q3 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a3", stop_reason: :stop))
    session.append_message(Mistri::Message.user("q4"))

    session.checkpoint(summary: "T", kept_from: 7, block: BLOCK, provider: :fake)
    first, kept, note = session.messages

    assert_equal :compaction, first.content.first.type
    assert_equal "q4", kept.text
    assert_equal "loaded_tools", note.reminder
    assert_includes note.text, "read_gauge"
  end

  def test_a_sealed_block_is_stored_with_no_summary_and_the_event_holds_no_text
    provider = Compacting.new(native: sealed_reply)
    session = seeded_session
    events = []

    result = Mistri::Agent.new(provider:, session:, compaction: settings)
                          .compact { |event| events << event }

    assert_nil result[:summary]
    assert_equal [:native, nil], events.last.to_h.values_at(:status, :content)
    assert_equal({ "id" => "cmp_1" }, session.last_compaction["block"])
    refute session.last_compaction.key?("summary")
    assert_nil session.messages.first.content.first.text
  end

  def test_the_gem_s_own_summary_after_a_sealed_block_repeats_the_block_and_asks_to_fold_it
    provider = Compacting.new(native: sealed_reply, turns: [{ text: "Folded." }])
    session = seeded_session
    Mistri::Agent.new(provider:, session:, compaction: settings).compact
    session.append_message(Mistri::Message.user("q3 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a3", stop_reason: :stop))

    Mistri::Agent.new(provider:, session:, compaction: settings(native: false)).compact
    asked = provider.requests.last[:messages]

    assert_equal Mistri::Compactor::CLOSING_UPDATE_PROMPT, asked.last.text
    assert_equal :compaction, asked.first.content.first.type
    assert_includes session.messages.first.text, "Folded."
  end

  def test_the_gem_s_own_summary_stands_after_the_kept_turns_where_the_provider_asks
    session = seeded_session
    after_kept_agent(session, [{ text: "First." }]).compact
    kept, summary = session.messages.each_slice(2).to_a

    assert session.last_compaction["after"]
    assert_equal %w[q2 a2], kept.map(&:text)
    assert summary.first.text.start_with?(Mistri::Compaction::SUMMARY_PREFACE_AFTER)
    assert_includes summary.first.text, "First."

    session.append_message(Mistri::Message.user("q3"))
    order = session.messages.map(&:text).map { |text| text.include?("First.") ? :summary : text }

    assert_equal ["q2", "a2", :summary, "q3"], order
  end

  def test_a_later_compaction_reads_a_summary_that_stands_after_the_kept_turns
    session = seeded_session
    after_kept_agent(session, [{ text: "First." }]).compact
    session.append_message(Mistri::Message.user("q3 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a3", stop_reason: :stop))
    provider = after_kept_agent(session, [{ text: "Second." }]).tap(&:compact)
                                                               .instance_variable_get(:@provider)
    sent = provider.requests.last[:messages].map(&:text)
    cut = session.last_compaction["kept_from"]
    _, text = Mistri::Compactor.send(:before_cut, session.replay, cut)

    assert_equal "q2", sent.first
    assert_includes sent[2], "First."
    assert_includes session.messages.last.text, "Second."
    refute(text.any? { |message| message.text.to_s.include?("Second.") })
  end

  def test_another_provider_refuses_a_session_that_holds_a_block
    block = Mistri::Content::Compaction.new(provider: :anthropic, data: BLOCK, text: "S")
    history = [Mistri::Message.assistant(content: [block], provider: :anthropic),
               Mistri::Message.user("go on")]
    openai = Mistri::Providers::OpenAI.new(api_key: "k")
    gemini = Mistri::Providers::Gemini.new(api_key: "k")
    refusals = [-> { openai.send(:build_body, "gpt-6.2-sol", history, nil, [], {}) },
                -> { gemini.send(:build_body, history, nil, [], {}) }]

    refusals.each do |build|
      error = assert_raises(Mistri::ConfigurationError) { build.call }

      assert_equal "this session holds a compaction that anthropic wrote, and only anthropic " \
                   "can read it", error.message
    end
  ensure
    [openai, gemini].compact.each(&:close)
  end

  def test_a_block_round_trips_and_is_estimated_by_its_text
    block = Mistri::Content::Compaction.new(provider: "anthropic", data: BLOCK, text: "x" * 400)
    message = Mistri::Message.assistant(content: [block])

    sealed = Mistri::Content::Compaction.new(provider: :openai, data: { "id" => "cmp_1" })

    assert_equal block, Mistri::Content.from_h(JSON.parse(JSON.generate(block.to_h)))
    assert_equal sealed, Mistri::Content.from_h(JSON.parse(JSON.generate(sealed.to_h)))
    assert_nil sealed.text
    assert_equal 100, Mistri::Compaction.estimate(message)
    assert_equal 0, Mistri::Compaction.estimate(Mistri::Message.assistant(content: [sealed]))
    assert_nil message.text
  end

  private

  def settings(**) = Mistri::Compaction.new(keep_recent: 10, **)

  def sealed_reply
    Mistri::Message.assistant(
      content: [Mistri::Content::Compaction.new(provider: :fake, data: { "id" => "cmp_1" })],
      stop_reason: :stop, model: "fake-1", usage: Mistri::Usage.new(input: 40, output: 9)
    )
  end

  def after_kept_agent(session, turns)
    provider = Class.new(Mistri::Providers::Fake) { def summary_after_kept? = true }.new(turns:)
    Mistri::Agent.new(provider:, session:, compaction: settings)
  end

  def seeded_session(thinking: false)
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("q1 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a1 " * 200, stop_reason: :stop))
    session.append_message(Mistri::Message.user("q2"))
    thought = Mistri::Content::Thinking.new(thinking: "Weigh it.", signature: "sig")
    content = thinking ? [thought, Mistri::Content::Text.new(text: "a2")] : "a2"
    session.append_message(Mistri::Message.assistant(content:, stop_reason: :stop,
                                                     provider: :anthropic,
                                                     model: "claude-opus-5-5"))
    session
  end
end
