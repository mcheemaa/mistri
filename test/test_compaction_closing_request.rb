# frozen_string_literal: true

require_relative "test_helper"

# An agent's summary request repeats the conversation up to the cut as its
# turns sent it and ends with the summary prompt, so it reads the session's
# prompt cache. A fallback, and a compaction outside an agent, get the text.
class TestCompactionClosingRequest < Minitest::Test
  COMPACTOR = Mistri::Compactor

  def test_the_request_is_the_conversation_with_the_agent_s_system_and_tools_then_the_prompt
    tool = Mistri::Tool.define("read", "Reads a note.") { "" }
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    agent = Mistri::Agent.new(provider:, session: seeded_session, system: "Be exact.",
                              tools: [tool], compaction: settings(max_tokens: 2_000))

    agent.compact
    request = provider.requests.first

    assert_equal ["q1 " * 50, "a1 " * 200, COMPACTOR::CLOSING_CHECKPOINT_PROMPT],
                 request[:messages].map(&:text)
    assert_equal "Be exact.", request[:options][:system]
    assert_equal(["read"], request[:options][:tools].map { |spec| spec[:name] })
    assert_equal 2_000, request[:options][:max_tokens]
    assert_empty request[:options].keys & %i[thinking reasoning cache]
    assert_equal "Summary.", agent.session.last_compaction["summary"]
  end

  def test_a_second_compaction_begins_with_the_last_summary_and_asks_to_fold_into_it
    provider = Mistri::Providers::Fake.new(turns: [{ text: "FIRST" }, { text: "SECOND" }])
    session = seeded_session
    agent = Mistri::Agent.new(provider:, session:, compaction: settings)

    agent.compact
    session.append_message(Mistri::Message.user("q3 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a3", stop_reason: :stop))
    agent.compact
    messages = provider.requests.last[:messages]

    assert_includes messages.first.text, "FIRST"
    assert_equal COMPACTOR::CLOSING_UPDATE_PROMPT, messages.last.text
    assert_includes session.messages.first.text, "SECOND"
  end

  def test_the_focus_a_host_set_follows_the_prompt
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    agent = Mistri::Agent.new(provider:, session: seeded_session,
                              compaction: settings(instructions: "Keep every date."))

    agent.compact

    assert_equal "#{COMPACTOR::CLOSING_CHECKPOINT_PROMPT}\nAdditional focus: Keep every date.\n",
                 provider.requests.first[:messages].last.text
  end

  def test_a_transform_of_the_context_sees_the_conversation_and_not_the_prompt
    seen = []
    transform = lambda do |messages|
      seen << messages.map(&:text)
      messages + [Mistri::Message.user("marker")]
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    agent = Mistri::Agent.new(provider:, session: seeded_session, compaction: settings,
                              transform_context: transform)

    agent.compact

    assert_equal ["q1 " * 50, "a1 " * 200], seen.first
    assert_equal ["marker", COMPACTOR::CLOSING_CHECKPOINT_PROMPT],
                 provider.requests.first[:messages].last(2).map(&:text)
  end

  def test_a_fallback_is_given_the_text_when_the_reply_to_the_request_is_no_summary
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: [{ name: "read" }] }])
    fallback = Mistri::Providers::Fake.new(turns: [{ text: "From the text." }])
    fallback.define_singleton_method(:model) { "fake-2" }
    agent = Mistri::Agent.new(provider:, session: seeded_session,
                              compaction: settings(fallback:))

    agent.compact
    request = fallback.requests.first

    assert_equal 1, request[:messages].length
    assert_includes request[:messages].first.text, "<conversation>"
    assert_equal COMPACTOR::SUMMARIZER_SYSTEM, request[:options][:system]
    refute request[:options][:cache]
    assert_equal "From the text.", agent.session.last_compaction["summary"]
  end

  def test_a_compaction_outside_an_agent_sends_the_text
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])

    COMPACTOR.call(session: seeded_session, provider:, settings:)

    assert_includes provider.requests.first[:messages].first.text, "<conversation>"
  end

  private

  def settings(**) = Mistri::Compaction.new(keep_recent: 10, **)

  def seeded_session
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("q1 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a1 " * 200, stop_reason: :stop))
    session.append_message(Mistri::Message.user("q2"))
    session.append_message(Mistri::Message.assistant(content: "a2", stop_reason: :stop))
    session
  end
end
