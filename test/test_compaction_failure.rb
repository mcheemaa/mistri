# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

# An incomplete summary must never replace the context needed to continue a session.
class TestCompactionFailure < Minitest::Test
  SETTINGS = Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 10)
  SUMMARY_USAGE = Mistri::Usage.new(input: 1_000, output: 48)
                               .with_cost(input: 1.0, output: 5.0)

  def test_nonempty_summaries_require_a_normal_stop
    (Mistri::StopReason::ALL - [:stop] + [nil]).each do |reason|
      reply = Mistri::Message.assistant(content: "private unfinished summary",
                                        stop_reason: reason, usage: SUMMARY_USAGE)
      expected = reason == :error ? "provider error" : "unexpected stop reason: #{reason.inspect}"

      assert_rejected(reply, expected)
    end
  end

  def test_a_normal_stop_requires_visible_nonblank_text
    [nil, "", " \n\t", Mistri::Content::Thinking.new(thinking: "not a summary")].each do |content|
      reply = Mistri::Message.assistant(content:, stop_reason: :stop, usage: SUMMARY_USAGE)

      assert_rejected(reply, "empty summary")
    end
  end

  def test_a_normal_stop_cannot_hide_a_tool_call_alongside_text
    call = Mistri::ToolCall.new(id: "unexpected", name: "save", arguments: {})
    reply = Mistri::Message.assistant(content: "private unfinished summary", tool_calls: [call],
                                      stop_reason: :stop, usage: SUMMARY_USAGE)

    assert_rejected(reply, "unexpected tool calls")
  end

  def test_provider_errors_keep_their_diagnostic_and_usage
    reply = Mistri::Message.assistant(content: "private unfinished summary", stop_reason: :error,
                                      error_message: "summarizer unavailable", usage: SUMMARY_USAGE)

    assert_rejected(reply, "summarizer unavailable")
  end

  def test_completed_text_with_thinking_does_not_need_prescribed_headings
    provider = Mistri::Providers::Fake.new(turns: [{ thinking: "considering the history",
                                                     text: "The export is ready.",
                                                     usage: SUMMARY_USAGE }])
    session = history

    result = Mistri::Compactor.call(session:, provider:, settings: SETTINGS)

    assert_equal "The export is ready.", result[:summary]
    assert_same SUMMARY_USAGE, result[:usage]
    assert_equal "The export is ready.", session.last_compaction.fetch("summary")
  end

  def test_manual_rejection_preserves_the_previous_checkpoint_across_reload
    Dir.mktmpdir do |directory|
      session = history(store: Mistri::Stores::JSONL.new(directory), checkpoint: true)
      path = File.join(directory, "compaction-test.jsonl")
      before_file = File.binread(path)
      before_replay = session.messages
      provider = Mistri::Providers::Fake.new(turns: [incomplete_turn])
      events = []

      error = assert_raises(Mistri::CompactionError) do
        Mistri::Agent.new(provider:, session:, compaction: SETTINGS).compact do |event|
          events << event.type
        end
      end
      reloaded = Mistri::Session.new(store: Mistri::Stores::JSONL.new(directory), id: session.id)

      assert_same SUMMARY_USAGE, error.usage
      assert_equal before_file, File.binread(path)
      assert_equal before_replay, reloaded.messages
      assert_equal session.last_compaction, reloaded.last_compaction
      assert_equal [:compacting], events
      assert_equal 1, provider.requests.length
    end
  end

  def test_automatic_rejection_retains_context_and_counts_usage_once
    [false, true].each do |checkpoint|
      session = history(checkpoint:)
      before = session.entries
      replay = session.messages
      turn_usage = Mistri::Usage.new(input: 500).with_cost(input: 1.0)
      provider = Mistri::Providers::Fake.new(turns: [incomplete_turn,
                                                     { text: "done", usage: turn_usage }])
      events = []

      result = Mistri::Agent.new(provider:, session:,
                                 compaction: SETTINGS).run("Continue.") do |event|
        events << event.type
      end

      assert_predicate result, :completed?
      assert_equal SUMMARY_USAGE + turn_usage, result.usage
      assert_equal 2, provider.requests.length
      assert_equal replay + [Mistri::Message.user("Continue.")], provider.requests.last[:messages]
      assert_equal before, session.entries.take(before.length)
      assert_equal(checkpoint ? 1 : 0, session.entries.count do |entry|
        entry["type"] == "compaction"
      end)
      assert_equal 1, events.count(:compacting)
      refute_includes events, :compaction
    end
  end

  def test_incomplete_summary_cost_can_stop_before_another_provider_call
    session = history(checkpoint: true)
    checkpoint = session.last_compaction
    provider = Mistri::Providers::Fake.new(turns: [incomplete_turn, { text: "must not run" }])
    budget = Mistri::Budget.new(cost_usd: SUMMARY_USAGE.cost.total / 2)

    result = Mistri::Agent.new(provider:, session:, compaction: SETTINGS, budget:).run("Continue.")

    assert_predicate result, :stopped_by_budget?
    assert_equal "budget_cost", result.error_message
    assert_equal SUMMARY_USAGE, result.usage
    assert_equal 1, provider.requests.length
    assert_equal checkpoint, session.last_compaction
  end

  def test_rejection_keeps_approval_gated_execution_resumable
    session = history(checkpoint: true)
    saved = []
    tool = Mistri::Tool.define("save", "Save the export.", needs_approval: true,
                                                           ends_turn: true) do
      saved << :saved
      "saved"
    end
    provider = Mistri::Providers::Fake.new(turns: [incomplete_turn,
                                                   { tool_calls: [{ name: "save" }] }])
    agent = Mistri::Agent.new(provider:, session:, tools: [tool], compaction: SETTINGS)

    result = agent.run("Save the export.")

    assert_predicate result, :awaiting_approval?
    assert_equal 1, result.pending.length
    assert_empty saved
    assert_equal SUMMARY_USAGE, result.usage

    reloaded = Mistri::Session.new(store: session.store, id: session.id)
    reloaded.approve(result.pending.first.id)
    resumed = Mistri::Agent.new(provider:, session: reloaded, tools: [tool],
                                compaction: false).resume

    assert_equal [:saved], saved
    assert_predicate resumed, :completed?
    assert_equal 2, provider.requests.length
  end

  private

  def history(store: Mistri::Stores::Memory.new, checkpoint: false)
    session = Mistri::Session.new(store:, id: "compaction-test")
    session.append_message(Mistri::Message.user("Original export rules. " * 80))
    session.append_message(Mistri::Message.assistant(content: "Source inspected. " * 80,
                                                     stop_reason: :stop))
    session.append_message(Mistri::Message.user("Retain this follow-up. " * 80))
    if checkpoint
      provider = Mistri::Providers::Fake.new(turns: [{ text: "Previous export rules." }])
      Mistri::Compactor.call(session:, provider:, settings: SETTINGS)
      session.append_message(Mistri::Message.assistant(content: "Ready to continue. " * 80,
                                                       stop_reason: :stop))
      session.append_message(Mistri::Message.user("Keep the export rules."))
    end
    session
  end

  def incomplete_turn
    { text: "private unfinished summary", stop_reason: :length, usage: SUMMARY_USAGE }
  end

  def assert_rejected(reply, diagnostic)
    session = history
    before = session.entries
    replay = session.messages
    events = []
    provider = Mistri::Providers::Fake.new
    provider.define_singleton_method(:stream) { |**| reply }

    error = assert_raises(Mistri::CompactionError) do
      Mistri::Compactor.call(session:, provider:, settings: SETTINGS) { |event| events << event.type }
    end

    assert_equal "summarization failed: #{diagnostic}", error.message
    refute_includes error.message, "private unfinished summary"
    assert_same reply.usage, error.usage
    assert_equal before, session.entries
    assert_equal replay, session.messages
    assert_nil session.last_compaction
    assert_equal [:compacting], events
  end
end
