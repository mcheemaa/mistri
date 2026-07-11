# frozen_string_literal: true

require_relative "test_helper"

class TestSessionApprovalAudit < Minitest::Test # rubocop:disable Metrics/ClassLength -- one log grammar
  def test_an_approval_request_must_follow_its_assistant_tool_call
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "write-1", name: "write", arguments: {})
    session.append("approval_request", "call" => call.to_h)

    assert_rejected_history(session, /without a prior assistant tool call/)
  end

  def test_legacy_request_is_accepted_when_it_exactly_mirrors_the_assistant_call
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "write-1", name: "write", arguments: { "value" => 7 },
                                signature: "signed", provider_call_id: "remote-1")
    session.append_message(Mistri::Message.assistant(
                             tool_calls: [call], stop_reason: Mistri::StopReason::TOOL_USE
                           ))
    session.append("approval_request", "call" => call.to_h)
    session.append("approval_decision", "call_id" => call.id, "approved" => true)
    ran = []
    tool = Mistri::Tool.define("write", "Write once.",
                               needs_approval: true,
                               schema: lambda {
                                 integer :value, "Value", required: true
                               }) do |arguments|
      ran << arguments
      "written"
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "done" }])

    result = Mistri::Agent.new(provider:, tools: [tool], session:).resume

    assert_predicate result, :completed?
    assert_equal [{ "value" => 7 }], ran
    assert_equal 1, provider.requests.length
  end

  def test_malformed_persisted_messages_fail_before_an_approved_call_can_run
    cases = {
      bad_stop_reason: lambda do |message|
        message["stop_reason"] = "bogus"
      end,
      unknown_content_block: lambda do |message|
        message["content"] << { "type" => "future_block", "value" => "opaque" }
      end
    }

    cases.each do |label, corrupt|
      session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
      call = Mistri::ToolCall.new(id: "write-1", name: "write", arguments: {})
      assistant = Mistri::Message.assistant(
        tool_calls: [call], stop_reason: Mistri::StopReason::TOOL_USE
      )
      message = JSON.parse(JSON.generate(assistant.to_h))
      corrupt.call(message)
      raw_append(session, "message", "message" => message)
      session.append("approval_request", "call" => call.to_h)
      session.append("approval_decision", "call_id" => call.id, "approved" => true)

      assert_rejected_history(session, /invalid persisted message/, label)
    end
  end

  def test_approval_decisions_require_an_exact_boolean
    session = approval_session
    session.append("approval_decision", "call_id" => "write-1", "approved" => "false")

    assert_rejected_history(session, /approved value is not true or false/)
  end

  def test_approval_requests_require_a_tool_use_assistant_turn
    [nil, Mistri::StopReason::STOP, Mistri::StopReason::ERROR,
     Mistri::StopReason::ABORTED, Mistri::StopReason::LENGTH,
     Mistri::StopReason::BUDGET].each do |reason|
      session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
      call = Mistri::ToolCall.new(id: "write-1", name: "write", arguments: {})
      session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: reason))
      session.append("approval_request", "call" => call.to_h)
      session.append("approval_decision", "call_id" => call.id, "approved" => true)

      assert_rejected_history(session, /did not stop for tool use/, reason.inspect)
    end
  end

  def test_normalized_approvals_require_a_structurally_usable_source_call
    sources = {
      malformed: Mistri::ToolCall.new(id: "write-1", name: "write", arguments: nil,
                                      arguments_error: "invalid_json"),
      scalar: Mistri::ToolCall.new(id: "write-1", name: "write", arguments: 7),
      over_limit: Mistri::ToolCall.new(id: "write-1", name: "write",
                                       arguments: Array.new(10_000))
    }

    sources.each do |label, source|
      %i[marker legacy].each do |shape|
        session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
        session.append_message(Mistri::Message.assistant(
                                 tool_calls: [source], stop_reason: :tool_use
                               ))
        prepared = Mistri::ToolCall.new(id: source.id, name: source.name, arguments: {})
        data = { "call" => prepared.to_h }
        if shape == :marker
          data["prepared_from"] = "assistant"
        else
          data["source_call"] = source.to_h
        end
        session.append("approval_request", data)
        session.append("approval_decision", "call_id" => source.id, "approved" => true)

        assert_rejected_history(session, /could not have been normalized/, [label, shape])
      end
    end
  end

  def test_approval_decisions_must_follow_a_matching_request
    cases = {
      orphan: lambda do |session|
        session.append("approval_decision", "call_id" => "other", "approved" => true)
      end,
      before_request: lambda do |session|
        call = append_assistant_call(session, "write-1")
        session.append("approval_decision", "call_id" => call.id, "approved" => true)
        session.append("approval_request", "call" => call.to_h)
      end
    }

    cases.each do |label, build|
      session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
      build.call(session)

      assert_rejected_history(session, /without a prior matching approval request/, label)
    end
  end

  def test_approval_decision_ids_must_be_valid
    invalid_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)
    [nil, 7, "", " \t", invalid_utf8].each do |id|
      session = approval_session
      raw_append(session, "approval_decision", "call_id" => id, "approved" => true)

      assert_rejected_history(session, /approval decision call IDs/)
    end
  end

  def test_an_approval_request_can_have_only_one_decision
    session = approval_session
    session.append("approval_decision", "call_id" => "write-1", "approved" => true)
    session.append("approval_decision", "call_id" => "write-1", "approved" => false)

    assert_rejected_history(session, /duplicate approval decision/)
  end

  def test_a_settled_tool_call_cannot_be_reopened_or_decided_again
    request_then_answer = approval_session
    request_then_answer.append("approval_decision", "call_id" => "write-1",
                                                    "approved" => true)
    append_tool_result(request_then_answer)
    request_then_answer.append("approval_decision", "call_id" => "write-1",
                                                    "approved" => true)

    assert_rejected_history(request_then_answer, /already answered tool call/)

    answer_then_request = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = append_assistant_call(answer_then_request, "write-1")
    append_tool_result(answer_then_request)
    answer_then_request.append("approval_request", "call" => call.to_h)

    assert_rejected_history(answer_then_request, /already answered tool call/)
  end

  def test_tool_results_require_a_unique_prior_call_with_the_same_name
    cases = {
      before_call: lambda do |session|
        append_tool_result(session)
        append_assistant_call(session, "write-1")
      end,
      unknown_call: lambda do |session|
        append_assistant_call(session, "write-1")
        append_tool_result(session, id: "other")
      end,
      wrong_name: lambda do |session|
        append_assistant_call(session, "write-1")
        append_tool_result(session, name: "delete")
      end,
      duplicate: lambda do |session|
        append_assistant_call(session, "write-1")
        2.times { append_tool_result(session) }
      end
    }
    messages = {
      before_call: /without a prior assistant tool call/,
      unknown_call: /without a prior assistant tool call/,
      wrong_name: /name does not match/,
      duplicate: /duplicate tool result/
    }

    cases.each do |label, build|
      session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
      build.call(session)

      assert_rejected_history(session, messages.fetch(label), label)
    end
  end

  def test_persisted_provider_call_ids_are_unique_within_an_assistant_turn
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    calls = %w[first second].map do |id|
      Mistri::ToolCall.new(id:, name: "write", arguments: {},
                           provider_call_id: "wire-duplicate")
    end
    session.append_message(Mistri::Message.assistant(
                             tool_calls: calls, provider: :gemini,
                             stop_reason: Mistri::StopReason::TOOL_USE
                           ))

    assert_rejected_history(session, /duplicate provider tool call ID/)
  end

  def test_direct_tool_results_preserve_assistant_call_order
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    calls = append_assistant_calls(session, %w[first second])
    append_tool_result(session, id: calls.last.id, name: calls.last.name)
    append_tool_result(session, id: calls.first.id, name: calls.first.name)

    assert_rejected_history(session, /tool results out of assistant call order/)
  end

  def test_approval_requests_preserve_assistant_call_order
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    calls = append_assistant_calls(session, %w[first second])
    session.append("approval_request", "call" => calls.last.to_h)
    session.append("approval_request", "call" => calls.first.to_h)

    assert_rejected_history(session, /approval requests out of assistant call order/)
  end

  def test_approved_tool_results_preserve_assistant_call_order
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    calls = append_assistant_calls(session, %w[first second])
    calls.each { |call| session.append("approval_request", "call" => call.to_h) }
    calls.reverse_each do |call|
      session.append("approval_decision", "call_id" => call.id, "approved" => true)
      append_tool_result(session, id: call.id, name: call.name)
    end

    assert_rejected_history(session, /approval tool results out of assistant call order/)
  end

  def test_direct_results_cannot_arrive_after_approval_settlement_begins
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    calls = append_assistant_calls(session, %w[direct approved])
    session.append("approval_request", "call" => calls.last.to_h)
    session.append("approval_decision", "call_id" => calls.last.id, "approved" => true)
    append_tool_result(session, id: calls.last.id, name: calls.last.name)
    append_tool_result(session, id: calls.first.id, name: calls.first.name)

    assert_rejected_history(session, /direct tool result after approval settlement began/)
  end

  def test_legacy_gemini_approval_cannot_resume_before_an_answered_same_name_sibling
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    calls = %w[risk safe].map do |suffix|
      Mistri::ToolCall.new(id: "write-#{suffix}", name: "write", arguments: {})
    end
    session.append_message(Mistri::Message.assistant(
                             tool_calls: calls, provider: :gemini,
                             stop_reason: Mistri::StopReason::TOOL_USE
                           ))
    append_tool_result(session, id: calls.last.id, name: calls.last.name)
    session.append("approval_request", "call" => calls.first.to_h)
    session.append("approval_decision", "call_id" => calls.first.id, "approved" => true)

    assert_rejected_history(session, /ambiguous Gemini approval/)
  end

  def test_tool_result_ids_and_names_must_be_nonblank_utf8_strings
    invalid_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)
    fields = {
      id: [nil, 7, "", " \t", invalid_utf8],
      name: [nil, 7, "", " \t", invalid_utf8]
    }

    fields.each do |field, values|
      values.each do |value|
        session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
        append_assistant_call(session, "write-1")
        data = { "tool_call_id" => "write-1", "tool_name" => "write" }
        data[field == :id ? "tool_call_id" : "tool_name"] = value
        raw_tool_result(session, data)

        assert_rejected_history(session, /tool result/, [field, value.inspect])
      end
    end
  end

  def test_a_parked_call_cannot_be_answered_before_its_decision
    session = approval_session
    append_tool_result(session)

    assert_rejected_history(session, /approval without a prior decision/)
  end

  def test_a_later_conversation_closes_unparked_calls_and_cannot_pass_a_parked_call
    stale = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = append_assistant_call(stale, "write-1")
    stale.append_message(Mistri::Message.user("continue after the crash"))
    stale.append("approval_request", "call" => call.to_h)

    assert_rejected_history(stale, /stale approval request/)

    parked = approval_session
    parked.append_message(Mistri::Message.user("continue without settling"))

    assert_rejected_history(parked, /continues past an unsettled approval/)
  end

  def test_a_result_cannot_arrive_after_the_call_was_crash_healed
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    append_assistant_call(session, "write-1")
    session.append_message(Mistri::Message.user("continue after the crash"))
    append_tool_result(session)

    assert_rejected_history(session, /late tool result for a crash-healed call/)
  end

  def test_non_message_appenders_do_not_close_the_approval_window
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = append_assistant_call(session, "write-1")
    session.append("steer", "id" => "s1", "message" => Mistri::Message.user("wait").to_h)
    session.append("custom_audit", "value" => 1)
    session.append("approval_request", "call" => call.to_h)

    call_ids = session.open_approvals.map { |approval| approval[:call].id }

    assert_equal ["write-1"], call_ids
  end

  def test_an_open_approval_must_retain_its_assistant_call_across_compaction
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("old"))
    call = append_assistant_call(session, "write-1")
    session.append("approval_request", "call" => call.to_h)
    session.append("compaction", "summary" => "summary", "kept_from" => 2,
                                 "tokens_before" => 1)

    assert_rejected_history(session, /assistant tool call was removed by compaction/)
  end

  def test_compaction_cannot_split_a_completed_tool_exchange
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("old"))
    append_assistant_call(session, "write-1")
    append_tool_result(session)
    session.append("compaction", "summary" => "summary", "kept_from" => 2,
                                 "tokens_before" => 1)

    assert_rejected_history(session, /splits a tool call from its result/)
  end

  def test_the_public_decision_api_rejects_a_second_decision_without_writing_it
    session = approval_session
    session.approve("write-1")
    before = session.entries.length

    error = assert_raises(Mistri::ConfigurationError) { session.deny("write-1") }

    assert_match(/already been decided/, error.message)
    assert_equal before, session.entries.length
    assert session.open_approvals.first[:decision]["approved"]
  end

  def test_open_approval_decisions_do_not_alias_the_store
    session = approval_session
    session.deny("write-1", note: "no")
    exposed = session.open_approvals.first[:decision]

    exposed["approved"] = true
    exposed["note"].replace("changed")

    durable = session.open_approvals.first[:decision]

    refute durable["approved"]
    assert_equal "no", durable["note"]
  end

  private

  def approval_session
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = append_assistant_call(session, "write-1")
    session.append("approval_request", "call" => call.to_h)
    session
  end

  def append_assistant_call(session, id)
    call = Mistri::ToolCall.new(id:, name: "write", arguments: {})
    session.append_message(Mistri::Message.assistant(
                             tool_calls: [call], stop_reason: Mistri::StopReason::TOOL_USE
                           ))
    call
  end

  def append_assistant_calls(session, names)
    calls = names.map do |name|
      Mistri::ToolCall.new(id: "#{name}-1", name:, arguments: {})
    end
    session.append_message(Mistri::Message.assistant(
                             tool_calls: calls, stop_reason: Mistri::StopReason::TOOL_USE
                           ))
    calls
  end

  def append_tool_result(session, id: "write-1", name: "write")
    session.append_message(Mistri::Message.tool(
                             content: "written", tool_call_id: id, tool_name: name
                           ))
  end

  def raw_tool_result(session, data)
    message = {
      "role" => "tool",
      "content" => [{ "type" => "text", "text" => "written" }]
    }.merge(data)
    raw_append(session, "message", "message" => message)
  end

  def assert_rejected_history(session, message, label = nil)
    ran = false
    tool = Mistri::Tool.define("write", "Write once.", needs_approval: true) do
      ran = true
      "written"
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "must not run" }])
    before = session.entries.length
    context = label&.to_s || "approval history"

    error = assert_raises(Mistri::ConfigurationError, context) do
      Mistri::Agent.new(provider:, tools: [tool], session:).resume
    end

    assert_match message, error.message, context
    refute ran, context
    assert_empty provider.requests, context
    assert_equal before, session.entries.length, context
  end

  def raw_append(session, type, data)
    session.store.append(session.id, { "type" => type }.merge(data))
  end
end # rubocop:enable Metrics/ClassLength
