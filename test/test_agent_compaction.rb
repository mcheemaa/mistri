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

  def test_one_run_compacts_twice_without_losing_tool_state
    secret = "Spectramoor-7a91"
    token = "continue-4f28"
    agent, session, provider, state = checkpoint_fixture(secret, token)
    events = []

    result = agent.run(
      "Open the checkpoint, close it with its token, then return its secret."
    ) do |event|
      events << event
    end

    assert_checkpoint_completion(result, state, secret, token)
    assert_compaction_sequence(session, provider, events)
    assert_summary_handoff(provider, secret)
    assert_durable_checkpoint(session, secret, token)
  end

  def test_a_cut_never_splits_parallel_tool_results
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    first_call = Mistri::ToolCall.new(id: "c1", name: "paint", arguments: {})
    second_call = Mistri::ToolCall.new(id: "c2", name: "dry", arguments: {})
    session.append_message(Mistri::Message.user("q1 " * 100))
    session.append_message(Mistri::Message.assistant(content: [first_call, second_call],
                                                     stop_reason: :tool_use))
    session.append_message(Mistri::Message.tool(content: "painted " * 100,
                                                tool_call_id: "c1", tool_name: "paint"))
    session.append_message(Mistri::Message.tool(content: "dried " * 100,
                                                tool_call_id: "c2", tool_name: "dry"))
    session.append_message(Mistri::Message.assistant(content: "done", stop_reason: :stop))

    provider = Mistri::Providers::Fake.new(turns: [{ text: "## Goal\nSummary." }])
    Mistri::Compactor.call(session:, provider:,
                           settings: Mistri::Compaction.new(keep_recent: 60))

    replayed = session.messages

    assert_equal %w[c1 c2], replayed.select(&:tool?).map(&:tool_call_id)

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

  def test_only_the_summary_wire_truncates_large_tool_results
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "c1", name: "inspect", arguments: {})
    output = "START:#{"x" * 3_000}MIDDLE_SENTINEL#{"y" * 3_000}:END"
    tool_result = Mistri::Message.tool(content: output, tool_call_id: "c1",
                                       tool_name: "inspect")
    session.append_message(Mistri::Message.user("inspect the artifact " * 40))
    session.append_message(Mistri::Message.assistant(content: [call], stop_reason: :tool_use))
    session.append_message(tool_result)
    session.append_message(Mistri::Message.user("continue " * 20))
    session.append_message(Mistri::Message.assistant(content: "ready", stop_reason: :stop))
    provider = Mistri::Providers::Fake.new(turns: [{ text: "## Goal\nContinue." }])

    Mistri::Compactor.call(session:, provider:,
                           settings: Mistri::Compaction.new(keep_recent: 10))

    summarized = Mistri::Compactor.send(:text_of, tool_result)
    prompt = provider.requests.first[:messages].first.text

    stored = session.entries.find do |entry|
      entry["type"] == "message" && entry.dig("message", "tool_name") == "inspect"
    end

    assert_truncated_summary(summarized, output, prompt)
    assert_equal output, Mistri::Message.from_h(stored["message"]).text
  end

  def test_a_failed_summary_does_not_move_the_replay_boundary
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("old context " * 80))
    session.append_message(Mistri::Message.assistant(content: "old answer " * 80,
                                                     stop_reason: :stop))
    session.append_message(Mistri::Message.user("continue"))
    provider = Mistri::Providers::Fake.new(turns: [{ error: "summarizer unavailable" }])
    before = session.entries

    assert_raises Mistri::CompactionError do
      Mistri::Compactor.call(session:, provider:,
                             settings: Mistri::Compaction.new(keep_recent: 10))
    end
    assert_equal before, session.entries
    assert_nil session.last_compaction
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

  private

  def checkpoint_fixture(secret, token)
    padding = ("checkpoint context " * 80).strip
    state = { opened: 0, closed_with: [] }
    tools = checkpoint_tools(secret, token, padding, state)
    provider = checkpoint_provider(secret, token)
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    settings = Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 20)
    agent = Mistri::Agent.new(provider:, session:, tools:, max_concurrency: 1,
                              budget: Mistri::Budget.new(turns: 4), compaction: settings)
    [agent, session, provider, state]
  end

  def checkpoint_tools(secret, token, padding, state)
    open_checkpoint = Mistri::Tool.define(
      "open_checkpoint", "Opens the checkpoint and returns its state."
    ) do
      state[:opened] += 1
      "CHECKPOINT_SECRET=#{secret}\nCONTINUATION_TOKEN=#{token}\n#{padding}"
    end
    close_checkpoint = Mistri::Tool.define(
      "close_checkpoint", "Closes the checkpoint with its continuation token.",
      schema: -> { string :token, "Continuation token", required: true }
    ) do |args|
      state[:closed_with] << args["token"]
      "checkpoint closed\n#{padding}"
    end
    [open_checkpoint, close_checkpoint]
  end

  def checkpoint_provider(secret, token)
    Mistri::Providers::Fake.new(turns: [
                                  { tool_calls: [{ id: "open", name: "open_checkpoint" }] },
                                  { text: "## Goal\nComplete the checkpoint protocol.\n\n" \
                                          "## Critical Context\n- (none)" },
                                  { tool_calls: [{ id: "close", name: "close_checkpoint",
                                                   arguments: { token: token } }] },
                                  { text: "## Goal\nComplete the checkpoint protocol.\n\n" \
                                          "## Critical Context\n- CHECKPOINT_SECRET=#{secret}" },
                                  { text: secret }
                                ])
  end

  def assert_checkpoint_completion(result, state, secret, token)
    assert_predicate result, :completed?
    assert_equal secret, result.text
    assert_equal 1, state[:opened]
    assert_equal [token], state[:closed_with]
  end

  def assert_compaction_sequence(session, provider, events)
    assert_equal 5, provider.requests.length
    assert_equal(2, events.count { |event| event.type == :compacting })
    assert_equal(2, events.count { |event| event.type == :compaction })
    assert_equal(2, session.entries.count { |entry| entry["type"] == "compaction" })
  end

  def assert_summary_handoff(provider, secret)
    first_summary, second_summary = provider.requests.values_at(1, 3).map do |request|
      request[:messages].first.text
    end
    final_request = provider.requests.last[:messages]
    remembered = final_request.select { |message| JSON.generate(message.to_h).include?(secret) }

    refute_includes first_summary, secret
    assert_includes second_summary, secret
    assert_equal [final_request.first], remembered
    assert final_request.first.text.start_with?(Mistri::Compaction::SUMMARY_PREFACE)
  end

  def assert_durable_checkpoint(session, secret, token)
    durable = session.entries.filter_map do |entry|
      Mistri::Message.from_h(entry["message"]) if entry["type"] == "message"
    end
    original_result = durable.find { |message| message.tool_name == "open_checkpoint" }

    assert_includes original_result.text, "CHECKPOINT_SECRET=#{secret}"
    assert_includes original_result.text, "CONTINUATION_TOKEN=#{token}"
  end

  def assert_truncated_summary(summarized, output, prompt)
    assert_equal Mistri::Compactor::TOOL_RESULT_MAX_CHARS, summarized.length
    assert summarized.start_with?("START:")
    assert summarized.end_with?(":END")
    assert_includes summarized, "tool result truncated; original length: #{output.length}"
    refute_includes summarized, "MIDDLE_SENTINEL"
    assert_includes prompt, summarized
    refute_includes prompt, "MIDDLE_SENTINEL"
  end
end
