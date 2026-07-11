# frozen_string_literal: true

require_relative "test_helper"

# Legacy compatibility is exact: old Gemini/Fake call_N histories remain
# usable without weakening the unique correlation IDs every new turn reserves.
class TestLegacyToolCallIdentity < Minitest::Test
  def test_settled_ids_reuse_across_turns_and_the_session_still_runs
    session = new_session
    session.append_message(Mistri::Message.user("look twice"))
    2.times { |round| append_answered_call(session, "call_1", result: "ok #{round}") }
    ran = false
    tool = Mistri::Tool.define("write", "Write.") do
      ran = true
      "written"
    end
    turns = [{ tool_calls: [{ id: "fresh-1", name: "write", arguments: {} }] }, { text: "done" }]
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), tools: [tool],
                              session:)

    assert_empty session.open_approvals
    assert_equal Set["call_1"], session.tool_call_ids

    result = agent.run("continue")

    assert_predicate result, :completed?
    assert ran, "a run on top of the legacy history executes normally"
    assert_equal 3, session.messages.count(&:tool?)
    assert_equal Set["call_1", "fresh-1"], session.tool_call_ids
  end

  def test_a_call_id_may_be_reused_after_its_approval_settled
    session = new_session
    call = append_legacy_call(session, "call_1")
    session.append("approval_request", "call" => call.to_h)
    session.append("approval_decision", "call_id" => call.id, "approved" => true)
    append_result(session, call, "written")
    append_answered_call(session, "call_1")

    assert_empty session.open_approvals
    assert_equal Set["call_1"], session.tool_call_ids
  end

  def test_only_the_known_wireless_gemini_and_fake_shape_may_reuse_ids
    cases = [
      ["custom", :gemini, nil],
      ["call_1", :openai, nil],
      ["call_1", nil, nil],
      ["call_1", :gemini, "wire-1"]
    ]
    cases.each do |id, provider, wire_id|
      session = new_session
      append_answered_call(session, id, provider:, provider_call_id: wire_id)
      append_answered_call(session, id, provider:, provider_call_id: wire_id && "wire-2")

      error = assert_raises(Mistri::ConfigurationError) { session.tool_call_ids }

      assert_match(/duplicate tool call ID/, error.message)
    end
  end

  def test_replay_heals_the_later_occurrence_after_an_answered_id
    session = new_session
    append_answered_call(session, "call_1", result: "first")
    append_legacy_call(session, "call_1")

    results = session.messages.select(&:tool?)
    healthy = results.filter_map { |message| message.text unless message.tool_error? }
    interrupted = results.filter_map { |message| message.text if message.tool_error? }

    assert_equal %w[first], healthy
    assert_equal [Mistri::Session::INTERRUPTED_RESULT], interrupted
    assert_equal Set["call_1"], session.tool_call_ids
  end

  def test_replay_heals_an_interrupted_occurrence_before_a_later_answer
    session = new_session
    append_legacy_call(session, "call_1")
    session.append_message(Mistri::Message.user("continue after the crash"))
    append_answered_call(session, "call_1", provider: :fake, result: "second")

    results = session.messages.select(&:tool?)

    assert_equal [Mistri::Session::INTERRUPTED_RESULT, "second"], results.map(&:text)
    assert_predicate results.first, :tool_error?
    refute_predicate results.last, :tool_error?
    assert_equal Set["call_1"], session.tool_call_ids
  end

  def test_literal_v05_fake_to_gemini_history_keeps_result_origins_separate
    session = new_session
    append_v05_exchange(session, provider: "fake", name: "first", result: "foreign")
    append_v05_exchange(session, provider: "gemini", name: "second", result: "native")

    assert_equal Set["call_1"], session.tool_call_ids

    contents = Mistri::Providers::Gemini::Serializer.contents(session.messages)
    first_result = contents[1][:parts].first
    second_result = contents[3][:parts].first

    assert first_result.key?(:text)
    refute first_result.key?(:functionResponse)
    assert_equal "second", second_result.dig(:functionResponse, :name)
    assert_equal({ "result" => "native" }, second_result.dig(:functionResponse, :response))
  end

  def test_a_stale_approval_cannot_authorize_a_reused_call
    session = new_session
    first = append_legacy_call(session, "call_1")
    session.append("approval_request", "call" => first.to_h)
    session.append("approval_decision", "call_id" => first.id, "approved" => true)
    append_result(session, first, "first")
    second = append_legacy_call(session, "call_1")
    session.append("approval_request", "call" => second.to_h)
    session.append("approval_decision", "call_id" => second.id, "approved" => true)
    ran = false
    tool = Mistri::Tool.define("write", "Write.", needs_approval: true) do
      ran = true
      "written"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: "I will verify first." },
                                             { text: "The session remains usable." }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool], session:)

    assert_empty session.open_approvals

    result = agent.resume

    assert_predicate result, :completed?
    refute ran
    interrupted = provider.requests.first[:messages].select(&:tool?).last

    assert_equal Mistri::Session::INTERRUPTED_RESULT, interrupted.text
    assert_predicate interrupted, :tool_error?
    assert_predicate agent.run("continue"), :completed?
  end

  def test_same_turn_duplicate_ids_still_fail_closed
    session = new_session
    calls = Array.new(2) { Mistri::ToolCall.new(id: "call_1", name: "write", arguments: {}) }
    session.append_message(Mistri::Message.assistant(tool_calls: calls, stop_reason: :tool_use,
                                                     provider: :gemini))

    error = assert_raises(Mistri::ConfigurationError) { session.tool_call_ids }

    assert_match(/duplicate tool call ID/, error.message)
  end

  def test_compaction_cannot_split_an_earlier_occurrence_from_its_result
    session = new_session
    session.append_message(Mistri::Message.user("start"))
    append_answered_call(session, "call_1")
    append_answered_call(session, "call_1")
    session.append("compaction", "summary" => "s", "kept_from" => 2)

    error = assert_raises(Mistri::ConfigurationError) { session.tool_call_ids }

    assert_match(/splits a tool call from its result/, error.message)
  end

  private

  def new_session
    Mistri::Session.new(store: Mistri::Stores::Memory.new)
  end

  def append_answered_call(session, id, provider: :gemini, provider_call_id: nil, result: "ok")
    call = Mistri::ToolCall.new(id:, name: "write", arguments: {}, provider_call_id:)
    session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use,
                                                     provider:))
    append_result(session, call, result)
    call
  end

  def append_legacy_call(session, id, provider: :gemini)
    call = Mistri::ToolCall.new(id:, name: "write", arguments: {})
    session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use,
                                                     provider:))
    call
  end

  def append_result(session, call, content)
    session.append_message(Mistri::Message.tool(content:, tool_call_id: call.id,
                                                tool_name: call.name))
  end

  def append_v05_exchange(session, provider:, name:, result:)
    session.append("message", "message" => {
                     "role" => "assistant", "provider" => provider,
                     "stop_reason" => "tool_use", "content" => [
                       { "type" => "tool_call", "id" => "call_1", "name" => name,
                         "arguments" => {} }
                     ]
                   })
    session.append("message", "message" => {
                     "role" => "tool", "tool_call_id" => "call_1", "tool_name" => name,
                     "content" => [{ "type" => "text", "text" => result }]
                   })
  end
end
