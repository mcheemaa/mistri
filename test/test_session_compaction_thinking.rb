# frozen_string_literal: true

require_relative "test_helper"

# Compaction changes the prefix without rewriting the durable thinking record.
class TestSessionCompactionThinking < Minitest::Test
  def setup
    @session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    @session.append_message(Mistri::Message.user("earlier context"))
  end

  def test_uncompacted_thinking_round_trips_unchanged
    message = assistant("original")
    @session.append_message(message)

    assert_equal message, @session.messages.last
  end

  def test_compaction_removes_only_pre_boundary_prefix_bound_thinking
    old = assistant("old", model: "claude-fable-5-1-20260901")
    @session.append_message(old)
    compact
    fresh = assistant("fresh")
    @session.append_message(fresh)
    original_entries = @session.entries

    replay = @session.replay

    assert_equal [nil, 1, 3], replay.map(&:last)
    assert_equal old.with(content: old.content.grep(Mistri::Content::Text)), replay[1].first
    assert_equal fresh, replay.last.first
    assert_equal replay, @session.replay, "repeated reads must keep the same signed prefix"
    assert_equal original_entries, @session.entries
    assert_equal old, Mistri::Message.from_h(@session.entries[1].fetch("message"))
  end

  def test_the_claude_5_5_models_are_prefix_bound
    stored = %w[claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5].map do |model|
      assistant(model, model:).tap { |message| @session.append_message(message) }
    end
    compact

    assert_empty @session.messages.flat_map(&:content).grep(Mistri::Content::Thinking)
    assert_equal(stored, @session.entries[1, 3].map do |entry|
      Mistri::Message.from_h(entry.fetch("message"))
    end)
  end

  def test_anthropic_thinking_is_prefix_bound_unless_the_model_predates_binding
    %w[claude-fable-5-2 claude-fable-5-1 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5
       claude-fable-5-2-20261109 claude-fable-6].each do |id|
      assert Mistri::Models.prefix_bound_thinking?(id), "#{id} binds its thinking"
    end
    %w[claude-fable-5 claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6
       claude-sonnet-5 claude-sonnet-4-6 claude-haiku-4-5 gpt-6.1-sol gemini-3.8-flash].each do |id|
      refute Mistri::Models.prefix_bound_thinking?(id), "#{id} does not bind its thinking"
    end
  end

  def test_an_anthropic_model_the_catalog_does_not_know_is_prefix_bound
    ["claude-fable-5-2", "claude-fable-6", nil].each_with_index do |model, index|
      @session.append_message(assistant("reply #{index}", model:))
    end
    compact

    assert_equal ["reply 0", "reply 1", "reply 2"], @session.messages.drop(1).map(&:text)
    assert_empty @session.messages.flat_map(&:content).grep(Mistri::Content::Thinking)
  end

  def test_repeated_compaction_invalidates_thinking_from_the_previous_prefix
    @session.append_message(assistant("first"))
    compact
    @session.append_message(assistant("second"))
    compact
    third = assistant("third")
    @session.append_message(third)

    replay = @session.messages

    assert_empty replay[1].content.grep(Mistri::Content::Thinking)
    assert_empty replay[2].content.grep(Mistri::Content::Thinking)
    assert_equal third, replay.last
    assert_equal(3, @session.entries.count { |entry| entry.dig("message", "role") == "assistant" })
  end

  def test_redacted_and_empty_thinking_are_removed_without_empty_wire_turns
    redacted = Mistri::Content::Thinking.new(thinking: "", signature: "redacted", redacted: true)
    empty = Mistri::Content::Thinking.new(thinking: "", signature: "empty")
    blank = Mistri::Content::Text.new(text: "")
    @session.append_message(assistant("hidden").with(content: [redacted]))
    @session.append_message(assistant("empty").with(content: [empty, blank]))
    visible = assistant("visible").with(content: [redacted, empty,
                                                  Mistri::Content::Text.new(text: "kept")])
    @session.append_message(visible)
    compact

    replay = @session.replay

    assert_equal [nil, 3], replay.map(&:last)
    assert_equal "kept", replay.last.first.text
    wire = Mistri::Providers::Anthropic::Serializer.messages(@session.messages)

    assert_equal [{ type: "text", text: "kept" }], wire.last[:content]
    assert_equal 5, @session.entries.length
  end

  def test_other_models_and_provider_metadata_remain_unchanged
    messages = [assistant("older", model: "claude-fable-5"),
                assistant("opus", model: "claude-opus-5"),
                assistant("foreign", model: "gpt-6-astra", provider: :openai),
                assistant("mismatched", provider: :gemini),
                assistant("plain").with(content: [Mistri::Content::Text.new(text: "no thinking")])]
    messages.each { |message| @session.append_message(message) }
    compact

    assert_equal messages, @session.messages.drop(1)
  end

  def test_tool_pairing_and_crash_healing_survive_thinking_removal
    calls = %w[answered interrupted].map do |id|
      Mistri::ToolCall.new(id:, name: "lookup", arguments: {})
    end
    original = assistant("checking")
    original = original.with(content: [*original.content, *calls], stop_reason: :tool_use)
    @session.append_message(original)
    @session.append_message(Mistri::Message.tool(content: "found", tool_call_id: "answered"))
    compact

    replay = @session.messages
    results = replay.select(&:tool?)

    assert_equal calls, replay.find(&:assistant?).tool_calls
    assert_equal %w[answered interrupted], results.map(&:tool_call_id)
    assert_equal "found", results.first.text
    assert_predicate results.last, :tool_error?
    wire = Mistri::Providers::Anthropic::Serializer.messages(replay)

    blocks = wire.flat_map { |message| message[:content] }

    refute(blocks.any? { |block| block[:type] == "thinking" })
    assert_equal original, Mistri::Message.from_h(@session.entries[1].fetch("message"))
  end

  def test_parked_approvals_remain_open_without_manufactured_results
    call = Mistri::ToolCall.new(id: "approval", name: "send", arguments: {})
    message = assistant("checking")
    message = message.with(content: [*message.content, call], stop_reason: :tool_use)
    @session.append_message(message)
    @session.append("approval_request", "call" => call.to_h)
    compact

    assert_equal([call], @session.open_approvals.map { |approval| approval[:call] })
    assert_empty @session.messages.select(&:tool?)
    assert_equal [call], @session.messages.find(&:assistant?).tool_calls

    executions = 0
    tool = Mistri::Tool.define("send", "Send after approval.", needs_approval: true) do
      executions += 1
      "sent"
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "done" }])
    @session.approve(call.id)
    result = Mistri::Agent.new(provider:, session: @session, tools: [tool]).resume

    assert_predicate result, :completed?
    assert_equal 1, executions
    assert_empty @session.open_approvals
    sent = provider.requests.first.fetch(:messages)

    assert_empty sent.find(&:assistant?).content.grep(Mistri::Content::Thinking)
    assert_equal "sent", sent.find(&:tool?).text
    assert_equal message, Mistri::Message.from_h(@session.entries[1].fetch("message"))
  end

  private

  def assistant(text, model: "claude-fable-5-1", provider: :anthropic)
    Mistri::Message.assistant(
      content: [Mistri::Content::Thinking.new(thinking: "reasoning", signature: "sig-#{text}"),
                Mistri::Content::Text.new(text:)],
      model:, provider:, stop_reason: :stop
    )
  end

  def compact
    @session.append("compaction", "summary" => "earlier context summary", "kept_from" => 1)
  end
end
