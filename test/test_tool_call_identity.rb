# frozen_string_literal: true

require_relative "test_helper"
require "delegate"

class TestToolCallIdentity < Minitest::Test
  def test_approval_request_mirrors_do_not_duplicate_assistant_call_ids
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "c1", name: "send", arguments: {})
    session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use))
    session.append("approval_request", "call" => call.to_h)

    assert_equal Set["c1"], session.tool_call_ids
  end

  def test_a_later_assistant_turn_cannot_reuse_a_persisted_call_id
    ran = 0
    tool = Mistri::Tool.define("write", "Write once.") do
      ran += 1
      "written"
    end
    turns = [tool_turn("same"), tool_turn("same"), tool_turn("corrected"), { text: "done" }]
    provider = Mistri::Providers::Fake.new(turns:)
    retries = Mistri::RetryPolicy.new(attempts: 1, base: 0, max_delay: 0)

    agent = Mistri::Agent.new(provider:, tools: [tool], retries:)
    result = agent.run("go")

    assert_predicate result, :completed?
    assert_equal 2, ran, "the rejected duplicate never reached the handler"
    calls = agent.session.messages.flat_map(&:tool_calls)
    retries_recorded = agent.session.entries.count { |entry| entry["type"] == "retry" }

    assert_equal %w[same corrected], calls.map(&:id)
    assert_equal 1, retries_recorded
  end

  def test_reusing_an_unanswered_call_id_in_history_fails_before_a_run_writes_or_calls_a_provider
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    append_assistant_call(session, "same")
    append_assistant_call(session, "same")
    provider = Mistri::Providers::Fake.new(turns: [{ text: "must not run" }])
    before = session.entries.length

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider:, session:).run("continue")
    end

    assert_match(/duplicate tool call ID/, error.message)
    assert_equal before, session.entries.length
    assert_empty provider.requests
  end

  # Releases before the identity audit synthesized per-turn IDs ("call_1")
  # for Gemini and the Fake provider, so answered reuse across turns is the
  # normal shape of a durable legacy history and must stay loadable.
  def test_settled_legacy_call_ids_reuse_across_turns_and_the_session_still_runs
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
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
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "call_1", name: "write", arguments: {})
    session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use))
    session.append("approval_request", "call" => call.to_h)
    session.append("approval_decision", "call_id" => "call_1", "approved" => true)
    session.append_message(Mistri::Message.tool(content: "written", tool_call_id: "call_1",
                                                tool_name: "write"))
    append_answered_call(session, "call_1")

    assert_empty session.open_approvals
    assert_equal Set["call_1"], session.tool_call_ids
  end

  def test_same_turn_duplicate_ids_still_fail_closed
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    calls = Array.new(2) { Mistri::ToolCall.new(id: "call_1", name: "write", arguments: {}) }
    session.append_message(Mistri::Message.assistant(tool_calls: calls, stop_reason: :tool_use))

    error = assert_raises(Mistri::ConfigurationError) { session.tool_call_ids }

    assert_match(/duplicate tool call ID/, error.message)
  end

  def test_compaction_still_cannot_split_a_retired_call_from_its_result
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("start"))
    append_answered_call(session, "call_1")
    append_answered_call(session, "call_1")
    session.append("compaction", "summary" => "s", "kept_from" => 2)

    error = assert_raises(Mistri::ConfigurationError) { session.tool_call_ids }

    assert_match(/splits a tool call from its result/, error.message)
  end

  def test_one_legacy_decision_cannot_execute_duplicate_approval_requests
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "write-1", name: "write", arguments: {})
    session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use))
    2.times { session.append("approval_request", "call" => call.to_h) }
    session.append("approval_decision", "call_id" => call.id, "approved" => true)
    ran = false
    tool = Mistri::Tool.define("write", "Write once.", needs_approval: true) do
      ran = true
      "written"
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "must not run" }])

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider:, tools: [tool], session:).resume
    end

    assert_match(/duplicate approval request ID/, error.message)
    refute ran
    assert_empty provider.requests
    assert_empty session.messages.select(&:tool?)
  end

  def test_an_approval_request_cannot_substitute_arguments_for_the_assistant_call
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    call = Mistri::ToolCall.new(id: "charge-1", name: "charge",
                                arguments: { "amount" => 5 }, signature: "signed",
                                provider_call_id: "remote-1")
    session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use))
    substituted = call.to_h.merge(arguments: { "amount" => 5000 })
    session.append("approval_request", "call" => substituted)
    session.append("approval_decision", "call_id" => call.id, "approved" => true)
    ran = false
    tool = Mistri::Tool.define("charge", "Charge.",
                               needs_approval: true,
                               schema: lambda {
                                 integer :amount, "Amount", required: true
                               }) do
      ran = true
      "charged"
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider: Mistri::Providers::Fake.new, tools: [tool], session:).resume
    end

    assert_match(/does not match its assistant tool call/, error.message)
    refute ran
    assert_empty session.messages.select(&:tool?)
  end

  def test_a_normalized_approval_references_the_preceding_provider_call
    normalizer = lambda do |arguments|
      { "recipient" => arguments.fetch("to") }
    end
    tool = Mistri::Tool.define("send", "Send.",
                               needs_approval: true,
                               argument_normalizer: normalizer,
                               schema: lambda {
                                 string :recipient, "Recipient", required: true
                               }) { "sent" }
    turns = [{ tool_calls: [
      { id: "send-1", name: "send", arguments: { "to" => "Ana" } }
    ] }]
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), tools: [tool])

    agent.run("go")

    approval = agent.session.entries.find { |entry| entry["type"] == "approval_request" }
    assistant = agent.session.entries.find do |entry|
      entry.dig("message", "role") == "assistant"
    end
    provider_call = assistant.dig("message", "content", 0)

    refute approval.key?("source_call")
    assert_equal "assistant", approval["prepared_from"]
    assert_equal "send-1", provider_call["id"]
    assert_equal({ "recipient" => "Ana" }, approval.dig("call", "arguments"))
    assert_equal Set["send-1"], agent.session.tool_call_ids
  end

  def test_approval_provenance_and_prepared_metadata_are_both_fail_closed
    call = Mistri::ToolCall.new(id: "send-1", name: "send", arguments: { "to" => "Ana" },
                                signature: "signed", provider_call_id: "remote-1")
    cases = {
      source_arguments: [call.to_h, call.to_h.merge(arguments: { "to" => "Mallory" })],
      prepared_name: [call.to_h.merge(name: "delete"), call.to_h],
      prepared_type: [call.to_h.merge(type: "text"), call.to_h]
    }

    cases.each do |label, (prepared, source)|
      session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
      session.append_message(Mistri::Message.assistant(tool_calls: [call],
                                                       stop_reason: :tool_use))
      session.append("approval_request", "call" => prepared, "source_call" => source)

      assert_raises(Mistri::ConfigurationError, label.to_s) { session.tool_call_ids }
    end
  end

  def test_malformed_persisted_ids_are_rejected_without_rebuilding_messages
    invalid_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)
    [nil, 7, "", " \t", invalid_utf8].each do |id|
      store = Mistri::Stores::Memory.new
      session = Mistri::Session.new(store:)
      store.append(session.id, raw_assistant_entry(id))

      assert_raises(Mistri::ConfigurationError, "accepted #{id.inspect}") do
        session.tool_call_ids
      end
    end
  end

  def test_malformed_persisted_names_and_signatures_fail_closed
    invalid_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)
    cases = [
      [nil, nil], ["", nil], [7, nil], [invalid_utf8, nil],
      ["write", ""], ["write", 7], ["write", invalid_utf8]
    ]
    cases.each do |name, signature|
      store = Mistri::Stores::Memory.new
      session = Mistri::Session.new(store:)
      entry = raw_assistant_entry("c1")
      call = entry.dig("message", "content", 0)
      call["name"] = name
      call["signature"] = signature unless signature.nil?
      store.append(session.id, entry)

      assert_raises(Mistri::ConfigurationError, "accepted #{[name, signature].inspect}") do
        session.tool_call_ids
      end
    end
  end

  def test_invalid_provider_call_ids_reject_the_whole_live_attempt
    cases = {
      non_string: [7, /must be strings/],
      invalid_utf8: ["\xFF".b.force_encoding(Encoding::UTF_8), /must be valid UTF-8/],
      blank: [" ", /must not be blank/]
    }

    cases.each do |label, (provider_call_id, message)|
      ran = false
      tool = Mistri::Tool.define("write", "Write once.") do
        ran = true
        "written"
      end
      turns = [{ tool_calls: [
        { id: "internal", provider_call_id:, name: "write", arguments: {} }
      ] }]
      provider = Mistri::Providers::Fake.new(turns:)

      agent = Mistri::Agent.new(provider:, tools: [tool], retries: nil)
      result = agent.run("go")

      assert_predicate result, :errored?, label
      assert_match message, result.message.error_message, label
      refute ran, label
      assert_empty agent.session.messages.flat_map(&:tool_calls), label
    end
  end

  def test_invalid_signatures_reject_the_whole_live_attempt
    cases = {
      non_string: 7,
      empty: "",
      whitespace: " \t",
      invalid_utf8: "\xFF".b,
      non_utf8: "signed".encode(Encoding::UTF_16LE)
    }
    cases.each do |label, signature|
      ran = false
      tool = Mistri::Tool.define("write", "Write once.") do
        ran = true
        "written"
      end
      turns = [{ tool_calls: [
        { id: "internal", signature:, name: "write", arguments: {} }
      ] }]
      provider = Mistri::Providers::Fake.new(turns:)
      agent = Mistri::Agent.new(provider:, tools: [tool], retries: nil)

      result = agent.run("go")

      assert_predicate result, :errored?, label
      assert_match(/tool call signatures must/, result.message.error_message, label)
      refute ran, label
      assert_empty agent.session.messages.flat_map(&:tool_calls), label
    end
  end

  def test_the_identity_audit_reads_a_store_once
    counter = Class.new(SimpleDelegator) do
      def loads = @loads || 0

      def load(id)
        @loads = loads + 1
        __getobj__.load(id)
      end
    end
    store = counter.new(Mistri::Stores::Memory.new)
    session = Mistri::Session.new(store:)
    append_assistant_call(session, "c1")
    before = store.loads

    assert_equal Set["c1"], session.tool_call_ids
    assert_equal 1, store.loads - before
  end

  private

  def tool_turn(id)
    { tool_calls: [{ id:, name: "write", arguments: {} }] }
  end

  def append_assistant_call(session, id)
    call = Mistri::ToolCall.new(id:, name: "write", arguments: {})
    session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use))
    call
  end

  def append_answered_call(session, id, provider: :gemini, result: "ok")
    call = Mistri::ToolCall.new(id:, name: "write", arguments: {})
    session.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use,
                                                     provider: provider))
    session.append_message(Mistri::Message.tool(content: result, tool_call_id: id,
                                                tool_name: "write"))
    call
  end

  def raw_assistant_entry(id)
    { "type" => "message", "message" => {
      "role" => "assistant", "content" => [
        { "type" => "tool_call", "id" => id, "name" => "write", "arguments" => {} }
      ]
    } }
  end
end
