# frozen_string_literal: true

require_relative "test_helper"

# Compaction behavior: automatic mid-run compaction, the manual button, the
# append-only entry log, iterative summaries, and the pairing guarantees that
# keep a compacted replay wire-valid.
class TestAgentCompaction < Minitest::Test
  def test_the_loop_compacts_automatically_and_continues
    big_usage = Mistri::Usage.new(input: 900, output: 100)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: "a" * 400, usage: big_usage },
                                             { text: "## Goal\nBuild the landing page." },
                                             { text: "second answer" }
                                           ])
    settings = Mistri::Compaction.new(window: 1_000, reserve: 50, keep_recent: 60)
    agent = Mistri::Agent.new(provider:, compaction: settings)
    events = []

    agent.run("first question")
    result = agent.run("second question") { |event| events << event }

    assert_predicate result, :completed?
    assert_equal "second answer", result.text
    assert(events.any? { |e| e.type == :compacting })
    assert(events.any? { |e| e.type == :compaction && e.content.include?("Build the landing") })

    final_request = provider.requests.last[:messages]

    assert_operator final_request.length, :<=, 2, "replay shrank to summary plus kept tail"
    assert final_request.first.text.start_with?(Mistri::Compaction::SUMMARY_PREFACE)
    assert_includes final_request.first.text, "Build the landing page."

    stored = agent.session.entries.select { |e| e["type"] == "message" }

    assert(stored.any? { |e| e.dig("message", "content", 0, "text") == "first question" },
           "the full history stays in the store")
  end

  def test_manual_compact_works_from_a_bare_session_and_provider
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    session.append_message(Mistri::Message.user("q1 " * 50))
    session.append_message(Mistri::Message.assistant(content: "a1 " * 200, stop_reason: :stop))
    session.append_message(Mistri::Message.user("q2"))
    session.append_message(Mistri::Message.assistant(content: "a2", stop_reason: :stop))

    provider = Mistri::Providers::Fake.new(turns: [{ text: "## Goal\nSummary here." }])
    result = Mistri::Compactor.call(session:, provider:,
                                    settings: Mistri::Compaction.new(keep_recent: 10))

    assert_includes result[:summary], "Summary here."
    assert_operator result[:tokens_after], :<, result[:tokens_before]
    assert_equal "q2", session.messages[1].text
    assert session.messages.first.text.start_with?(Mistri::Compaction::SUMMARY_PREFACE)
  end

  def test_a_small_session_has_nothing_worth_compacting
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("hello"))

    result = Mistri::Compactor.call(session:, provider: Mistri::Providers::Fake.new)

    assert_nil result
    assert_nil session.last_compaction
  end

  def test_the_second_compaction_updates_the_first_summary
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    provider = Mistri::Providers::Fake.new(turns: [{ text: "## Goal\nFIRST" },
                                                   { text: "## Goal\nSECOND" }])
    settings = Mistri::Compaction.new(keep_recent: 10)
    2.times do |round|
      session.append_message(Mistri::Message.user("question #{round} " * 40))
      session.append_message(Mistri::Message.assistant(content: "answer #{round} " * 40,
                                                       stop_reason: :stop))
      session.append_message(Mistri::Message.user("next"))
      Mistri::Compactor.call(session:, provider:, settings:)
    end

    summarizer_prompt = provider.requests.last[:messages].first.text

    assert_includes summarizer_prompt, "<previous-summary>"
    assert_includes summarizer_prompt, "FIRST"
    assert_includes session.messages.first.text, "SECOND"
  end

  def test_a_cut_never_splits_a_tool_pair
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "c1", name: "paint", arguments: {})
    session.append_message(Mistri::Message.user("q1 " * 100))
    session.append_message(Mistri::Message.assistant(content: [call], stop_reason: :tool_use))
    session.append_message(Mistri::Message.tool(content: "painted " * 100,
                                                tool_call_id: "c1", tool_name: "paint"))
    session.append_message(Mistri::Message.user("q2"))
    session.append_message(Mistri::Message.assistant(content: "done", stop_reason: :stop))

    provider = Mistri::Providers::Fake.new(turns: [{ text: "## Goal\nSummary." }])
    Mistri::Compactor.call(session:, provider:,
                           settings: Mistri::Compaction.new(keep_recent: 60))

    replayed = session.messages
    replayed.select(&:tool?).each do |result|
      called = replayed.any? do |m|
        m.assistant? && m.tool_calls.any? { |c| c.id == result.tool_call_id }
      end

      assert called, "tool result #{result.tool_call_id} lost its call in replay"
    end
    # The compacted replay serializes cleanly for every provider.
    Mistri::Providers::Anthropic::Serializer.messages(replayed)
    Mistri::Providers::OpenAI::Serializer.input_items(replayed)
    Mistri::Providers::Gemini::Serializer.contents(replayed)
  end

  def test_compaction_keeps_a_parked_approval_resumable
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    session.append_message(Mistri::Message.user("earlier context " * 50))
    session.append_message(Mistri::Message.assistant(content: "noted " * 50, stop_reason: :stop))

    sent = []
    gated = Mistri::Tool.define("send", "Sends.", needs_approval: true) do
      sent << :sent
      "sent"
    end
    send_call = { tool_calls: [{ name: "send", arguments: {} }] }
    first = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns: [send_call]),
                              tools: [gated], session:, compaction: false)
    call = first.run("send it").pending.first

    result = Mistri::Compactor.call(session:, provider: Mistri::Providers::Fake.new(
      turns: [{ text: "## Goal\nSummary." }]
    ), settings: Mistri::Compaction.new(keep_recent: 10))

    refute_nil result, "history before the parked turn compacts"
    assert(session.messages.any? { |m| m.assistant? && m.tool_calls.any? },
           "the parked turn survives in replay")

    session.approve(call.id)
    resumed = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns: [{ text: "Sent!" }]),
                                tools: [gated],
                                session: Mistri::Session.new(store:, id: session.id),
                                compaction: false).resume

    assert_predicate resumed, :completed?
    assert_equal [:sent], sent
  end
end
