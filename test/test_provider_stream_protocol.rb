# frozen_string_literal: true

require_relative "test_helper"

# Malformed provider block lifecycles fail before a streamed fragment can
# become an executable tool call or an unmatched host event.
class TestProviderStreamProtocol < Minitest::Test
  class ScriptedProvider
    def initialize(message)
      @message = message
    end

    def model = "protocol-test"
    def prices_usage? = true

    def stream(**)
      if block_given?
        yield Mistri::Event.new(type: :error, reason: @message.stop_reason,
                                message: @message, error_message: @message.error_message)
      end
      @message
    end
  end

  def test_openai_output_item_lifecycle_is_correlated_before_commit
    function = { "type" => "function_call", "id" => "fc_1",
                 "call_id" => "call_1", "name" => "write", "arguments" => "{}" }
    message = { "type" => "message", "id" => "msg_1", "content" => [] }
    cases = {
      overlapping_start: [added(function), added(message)],
      done_without_start: [done(function)],
      changed_kind: [added(message), done(function)],
      changed_id: [added(function), done(function.merge("id" => "fc_2"))],
      changed_output_index: [added(function, output_index: 0),
                             done(function, output_index: 1)],
      mismatched_delta: [added(function),
                         { "type" => "response.output_text.delta",
                           "delta" => "not arguments" }],
      changed_delta_item: [added(function),
                           { "type" => "response.function_call_arguments.delta",
                             "item_id" => "fc_2", "delta" => "{}" }]
    }

    cases.each do |label, records|
      events = []
      result = drive_openai(events, [*records, openai_terminal])

      assert_protocol_error(result, events, label)
    end
  end

  def test_anthropic_content_block_lifecycle_is_correlated_before_commit
    start = anthropic_start
    cases = {
      overlapping_start: [start, anthropic_start(index: 1)],
      mismatched_delta_kind: [start, anthropic_delta(0, "text_delta", "text" => "wrong")],
      mismatched_delta_index: [start, anthropic_delta(1, "input_json_delta",
                                                      "partial_json" => "{}")],
      mismatched_stop_index: [start, { "type" => "content_block_stop", "index" => 1 }],
      content_after_message_delta: [
        { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" },
          "usage" => {} },
        start
      ]
    }

    cases.each do |label, records|
      events = []
      result = drive_anthropic(events, [*records, *anthropic_terminal])

      assert_protocol_error(result, events, label)
    end
  end

  def test_unknown_anthropic_blocks_keep_their_wire_position_without_becoming_content
    events = []
    records = [
      { "type" => "content_block_start", "index" => 0,
        "content_block" => { "type" => "future_server_block" } },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "input_json_delta", "partial_json" => "{}" } },
      { "type" => "content_block_stop", "index" => 0 },
      { "type" => "content_block_start", "index" => 1,
        "content_block" => { "type" => "text" } },
      { "type" => "content_block_delta", "index" => 1,
        "delta" => { "type" => "text_delta", "text" => "kept" } },
      { "type" => "content_block_stop", "index" => 1 },
      { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" }, "usage" => {} },
      { "type" => "message_stop" }
    ]

    result = drive_anthropic(events, records)

    assert_equal "kept", result.text
    assert_equal %i[text_start text_delta text_end done], events.map(&:type)
  end

  def test_misindexed_anthropic_arguments_never_reach_policy_or_persistence
    message = drive_anthropic([], [
                                anthropic_start,
                                anthropic_delta(1, "input_json_delta",
                                                "partial_json" => '{"amount":999}'),
                                { "type" => "content_block_stop", "index" => 1 },
                                *anthropic_terminal
                              ])
    touched = []
    tool = Mistri::Tool.define(
      "write", "Writes once.",
      needs_approval: ->(*) { touched << :policy },
      schema: -> { integer :amount, "Amount", required: true }
    ) { touched << :handler }
    agent = Mistri::Agent.new(provider: ScriptedProvider.new(message), tools: [tool],
                              retries: false)

    result = agent.run("write")

    assert_predicate result, :errored?
    assert_empty touched
    assert_empty agent.session.messages.flat_map(&:tool_calls)
    assert_empty agent.session.messages.select(&:tool?)
  end

  def test_anthropic_rejects_nonempty_tool_input_before_policy
    start = anthropic_start
    start["content_block"]["input"] = { "risk" => true }
    message = drive_anthropic([], [start, *anthropic_terminal])
    touched = []
    tool = Mistri::Tool.define(
      "write", "Writes once.",
      needs_approval: lambda { |args|
        touched << [:policy, args]
        args["risk"]
      },
      input_schema: { type: "object" }
    ) { touched << :handler }
    agent = Mistri::Agent.new(provider: ScriptedProvider.new(message), tools: [tool],
                              retries: false)

    result = agent.run("write")

    assert_predicate result, :errored?
    assert_empty touched
    assert_empty agent.session.messages.flat_map(&:tool_calls)
    assert_empty agent.session.messages.select(&:tool?)
  end

  def test_terminal_records_fence_later_tool_content_for_every_provider
    messages = {
      anthropic: drive_anthropic([], [
                                   { "type" => "message_stop" },
                                   anthropic_start,
                                   anthropic_delta(0, "input_json_delta",
                                                   "partial_json" => '{"amount":999}'),
                                   { "type" => "content_block_stop", "index" => 0 }
                                 ]),
      openai: drive_openai([], [
                             openai_terminal,
                             added(openai_function),
                             done(openai_function)
                           ]),
      gemini: drive_gemini([], [
                             { "candidates" => [{ "finishReason" => "STOP" }] },
                             { "candidates" => [{ "content" => { "parts" => [{
                               "functionCall" => { "name" => "write",
                                                   "args" => { "amount" => 999 } }
                             }] } }] }
                           ])
    }

    messages.each do |provider_name, message|
      touched = []
      tool = Mistri::Tool.define(
        "write", "Writes once.", needs_approval: ->(*) { touched << :policy },
                                 schema: -> { integer :amount, "Amount", required: true }
      ) { touched << :handler }
      agent = Mistri::Agent.new(provider: ScriptedProvider.new(message), tools: [tool],
                                retries: false)

      result = agent.run("write")

      assert_predicate result, :errored?, provider_name
      assert_empty touched, provider_name
      assert_empty agent.session.messages.flat_map(&:tool_calls), provider_name
      assert_empty agent.session.messages.select(&:tool?), provider_name
    end
  end

  def test_terminal_semantics_cannot_authorize_a_tool_call
    messages = {}
    %w[response.failed response.incomplete].each do |type|
      messages[type] = drive_openai([], [
                                      added(openai_function),
                                      done(openai_function),
                                      { "type" => type,
                                        "response" => { "status" => "completed" } }
                                    ])
    end
    function = { "functionCall" => {
      "name" => "write", "args" => { "amount" => 999 }
    } }
    future_stop = {
      "candidates" => [{ "content" => { "parts" => [function] },
                         "finishReason" => "FUTURE_SAFETY_BLOCK" }]
    }
    messages["gemini_future_reason"] = drive_gemini([], [future_stop])

    messages.each do |label, message|
      assert_equal :error, message.stop_reason, label
      assert message.tool_calls.all?(&:arguments_error?), "#{label} kept a usable call"
      assert_message_cannot_run(message, label)
    end
  end

  private

  def added(item, output_index: nil)
    { "type" => "response.output_item.added", "item" => item,
      "output_index" => output_index }.compact
  end

  def done(item, output_index: nil)
    { "type" => "response.output_item.done", "item" => item,
      "output_index" => output_index }.compact
  end

  def openai_terminal
    { "type" => "response.completed", "response" => { "status" => "completed" } }
  end

  def openai_function
    { "type" => "function_call", "id" => "fc_1", "call_id" => "call_1",
      "name" => "write", "arguments" => '{"amount":999}' }
  end

  def anthropic_start(index: 0)
    { "type" => "content_block_start", "index" => index,
      "content_block" => { "type" => "tool_use", "id" => "toolu_1", "name" => "write" } }
  end

  def anthropic_delta(index, type, fields)
    { "type" => "content_block_delta", "index" => index,
      "delta" => { "type" => type }.merge(fields) }
  end

  def anthropic_terminal
    [{ "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" }, "usage" => {} },
     { "type" => "message_stop" }]
  end

  def drive_openai(events, records)
    assembler = Mistri::Providers::OpenAI::Assembler.new(model: "gpt-5.5")
    records.each { |record| assembler.feed(record) { |event| events << event } }
    assembler.finish { |event| events << event }
  end

  def drive_anthropic(events, records)
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-4-8")
    records.each { |record| assembler.feed(record) { |event| events << event } }
    assembler.finish { |event| events << event }
  end

  def drive_gemini(events, records)
    assembler = Mistri::Providers::Gemini::Assembler.new(model: "gemini-2.5-flash")
    records.each { |record| assembler.feed(record) { |event| events << event } }
    assembler.finish { |event| events << event }
  end

  def assert_protocol_error(result, events, label)
    assert_equal :error, result.stop_reason, label
    assert result.tool_calls.none? { |call| !call.arguments_error? },
           "#{label} kept a usable call"
    assert_equal events.count { |event| event.type.to_s.end_with?("_start") },
                 events.count { |event| event.type.to_s.end_with?("_end") }, label
    assert_equal :error, events.last.type, label
    assert Mistri::RetryPolicy.new.retryable?(result.error), "#{label} did not retry"
  end

  def assert_message_cannot_run(message, label)
    touched = []
    tool = Mistri::Tool.define(
      "write", "Writes once.", needs_approval: ->(*) { touched << :policy },
                               schema: -> { integer :amount, "Amount", required: true }
    ) { touched << :handler }
    agent = Mistri::Agent.new(provider: ScriptedProvider.new(message), tools: [tool],
                              retries: false)

    result = agent.run("write")

    assert_predicate result, :errored?, label
    assert_empty touched, label
    assert_empty agent.session.messages.flat_map(&:tool_calls), label
    assert_empty agent.session.messages.select(&:tool?), label
  end
end
