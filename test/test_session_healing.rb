# frozen_string_literal: true

require_relative "test_helper"
require "delegate"

# A run killed mid-tool (deploy, crash) persists an assistant turn whose tool
# calls have no results; both Anthropic and OpenAI reject such a context on
# every later turn, bricking the session. Replay heals it: unsettled calls get
# a synthesized interrupted result, while calls parked for human approval stay
# open for resume to settle. The stored log is never rewritten.
class TestSessionHealing < Minitest::Test
  INTERRUPTED = Mistri::Session::INTERRUPTED_RESULT

  def bricked_session
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    calls = [Mistri::ToolCall.new(id: "a", name: "lookup", arguments: {}),
             Mistri::ToolCall.new(id: "b", name: "purge", arguments: {})]
    session.append_message(Mistri::Message.user("clean up"))
    session.append_message(Mistri::Message.assistant(tool_calls: calls))
    session.append_message(Mistri::Message.tool(content: "found 3", tool_call_id: "a",
                                                tool_name: "lookup"))
    session
  end

  def test_replay_synthesizes_results_for_calls_the_crash_left_dangling
    session = bricked_session

    answers = session.messages.select(&:tool?)

    assert_equal %w[a b], answers.map(&:tool_call_id).sort
    interrupted = answers.find { |message| message.tool_call_id == "b" }

    assert_equal INTERRUPTED, interrupted.text
    assert_match(/may have executed.*verify/i, interrupted.text)
    assert_predicate interrupted, :tool_error?
    assert_equal 1, session.entries.count { |e| e.dig("message", "role") == "tool" },
                 "the stored log gained nothing"
  end

  def test_gemini_replay_keeps_persisted_and_healed_siblings_in_call_order
    cases = [
      ["call_1", "first", [{ "result" => "first" }, { "error" => INTERRUPTED }]],
      ["call_2", "second", [{ "error" => INTERRUPTED }, { "result" => "second" }]]
    ]
    cases.each do |answered_id, content, expected|
      session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
      calls = %w[call_1 call_2].map do |id|
        Mistri::ToolCall.new(id:, name: "lookup", arguments: {})
      end
      session.append_message(Mistri::Message.assistant(tool_calls: calls,
                                                       stop_reason: :tool_use,
                                                       provider: :gemini))
      session.append_message(Mistri::Message.tool(content:, tool_call_id: answered_id,
                                                  tool_name: "lookup"))

      contents = Mistri::Providers::Gemini::Serializer.contents(session.messages)
      responses = contents.last[:parts].map { |part| part[:functionResponse][:response] }

      assert_equal expected, responses, answered_id
    end
  end

  def test_a_resumed_run_sends_a_fully_paired_context
    session = bricked_session
    provider = Mistri::Providers::Fake.new(turns: [{ text: "picking up where we left off" }])
    agent = Mistri::Agent.new(provider: provider, session: session)

    result = agent.run("continue")

    assert_predicate result, :completed?
    sent = provider.requests.first[:messages]
    calls = sent.flat_map { |m| m.tool_calls.map(&:id) }
    answered = sent.select(&:tool?).map(&:tool_call_id)

    assert_equal calls.sort, answered.uniq.sort, "every call reached the wire answered"
  end

  def test_replay_reads_the_store_exactly_once
    counter = Class.new(SimpleDelegator) do
      def loads = @loads || 0

      def load(id)
        @loads = loads + 1
        __getobj__.load(id)
      end
    end
    store = counter.new(Mistri::Stores::Memory.new)
    session = Mistri::Session.new(store: store)
    session.append_message(Mistri::Message.user("hi"))

    before = store.loads
    session.replay

    assert_equal 1, store.loads - before, "context assembly is one store read, healing included"
  end

  def test_replay_does_not_deserialize_messages_removed_by_compaction
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    store.append(session.id, {
                   "type" => "message",
                   "message" => { "role" => "invalid-before-compaction", "content" => [] }
                 })
    session.append("compaction", "summary" => "old context", "kept_from" => 1)

    replay = session.messages

    assert_equal 1, replay.length
    assert_includes replay.first.text, "old context"
  end

  def test_calls_parked_for_approval_are_not_healed_away
    gated = Mistri::Tool.define("send", "S.", needs_approval: true) { "sent" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send", arguments: {} }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider: provider, tools: [gated])
    suspended = agent.run("send it")

    assert_predicate suspended, :awaiting_approval?
    assert_empty agent.session.messages.select(&:tool?),
                 "a parked call belongs to the approval flow, not the healer"

    agent.session.approve(suspended.pending.first.id)
    result = agent.resume

    assert_predicate result, :completed?
    assert_includes agent.session.messages.select(&:tool?).map(&:text), "sent"
  end

  def test_approval_reconstruction_preserves_null_and_argument_errors
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    null = { "type" => "tool_call", "id" => "null", "name" => "inspect",
             "arguments" => nil }
    bad = { "type" => "tool_call", "id" => "bad", "name" => "inspect",
            "arguments" => nil, "arguments_error" => "invalid_json" }
    session.append("message", "message" => {
                     "role" => "assistant", "content" => [null, bad],
                     "stop_reason" => "tool_use"
                   })
    session.append("approval_request", "call" => null)
    session.append("approval_request", "call" => bad)

    calls = session.open_approvals.map { |entry| entry[:call] }

    assert_nil calls.first.arguments
    assert_nil calls.first.arguments_error
    assert_nil calls.last.arguments
    assert_equal "invalid_json", calls.last.arguments_error
  end
end
