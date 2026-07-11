# frozen_string_literal: true

require_relative "test_helper"

# Tool-call identity and abort are execution boundaries: neither malformed
# provider metadata nor a late stop may reach policy or create an approval.
class TestToolCallLifecycleBoundary < Minitest::Test # rubocop:disable Metrics/ClassLength -- one boundary matrix
  class ScriptedProvider
    attr_reader :requests

    def initialize(*turns)
      @turns = turns
      @requests = []
    end

    def model = "custom-1"

    def prices_usage? = true

    def stream(messages: [], **)
      @requests << messages
      message = @turns.shift || raise(Mistri::ConfigurationError, "no scripted turn left")
      type = message.stop_reason == Mistri::StopReason::ERROR ? :error : :done
      if block_given?
        yield Mistri::Event.new(type:, reason: message.stop_reason, message:,
                                error_message: message.error_message)
      end
      message
    end
  end

  def test_malformed_ids_fail_the_attempt_before_persistence_policy_or_execution
    cases = {
      missing: nil,
      non_string: 7,
      empty: "",
      whitespace: " \n\t",
      invalid_utf8: "\xFF".b,
      non_utf8: "call".encode(Encoding::UTF_16LE)
    }

    cases.each do |label, id|
      assert_malformed_id_rejected(label, id)
    end
  end

  def test_malformed_names_fail_the_attempt_before_persistence_policy_or_execution
    cases = {
      missing: nil,
      non_string: 7,
      empty: "",
      whitespace: " \n\t",
      invalid_utf8: "\xFF".b,
      non_utf8: "write".encode(Encoding::UTF_16LE)
    }

    cases.each do |label, name|
      call = Mistri::ToolCall.new(id: "call", name:, arguments: {})

      assert_malformed_call_rejected(label, call)
    end
  end

  def test_duplicate_ids_retry_the_entire_attempt_and_run_only_a_clean_retry
    state = duplicate_retry_scenario

    result = state[:agent].run("go") { |event| state[:events] << event }

    assert_clean_retry_execution(result, state)
    assert_malformed_attempt_not_persisted(state)
  end

  def test_duplicate_provider_call_ids_fail_before_persistence_or_execution
    calls = %w[first second].map do |id|
      Mistri::ToolCall.new(id:, name: "write", arguments: {},
                           provider_call_id: "wire-duplicate")
    end
    message = Mistri::Message.assistant(
      tool_calls: calls, stop_reason: Mistri::StopReason::TOOL_USE
    )
    provider = ScriptedProvider.new(message)
    ran = false
    tool = Mistri::Tool.define("write", "Writes.") { ran = true }
    agent = Mistri::Agent.new(provider:, tools: [tool], retries: false)

    result = agent.run("go")

    assert_predicate result, :errored?
    refute ran
    assert_empty agent.session.messages.flat_map(&:tool_calls)
    assert_empty agent.session.messages.select(&:tool?)
  end

  def test_non_assistant_provider_messages_never_reach_tool_execution
    %i[system user tool].each do |role|
      call = Mistri::ToolCall.new(id: "call-1", name: "write", arguments: {})
      message = Mistri::Message.new(
        role:, content: [call], tool_call_id: ("source" if role == :tool),
        tool_name: ("write" if role == :tool), stop_reason: Mistri::StopReason::TOOL_USE
      )
      provider = ScriptedProvider.new(message)
      ran = false
      tool = Mistri::Tool.define("write", "Writes.") { ran = true }
      agent = Mistri::Agent.new(provider:, tools: [tool], retries: false)

      result = agent.run("go")

      assert_predicate result, :errored?, role
      refute ran, role
      assert_empty agent.session.messages.flat_map(&:tool_calls), role
      assert_empty agent.session.messages.select(&:tool?), role
    end
  end

  def test_incomplete_provider_calls_are_not_persisted_or_run
    call = Mistri::ToolCall.new(id: "call-1", name: "write", arguments: nil,
                                arguments_error: "incomplete")
    message = Mistri::Message.assistant(
      tool_calls: [call], stop_reason: Mistri::StopReason::ERROR,
      error_message: "stream ended", error: { "type" => "TruncatedStream" }
    )
    provider = ScriptedProvider.new(message)
    ran = false
    tool = Mistri::Tool.define("write", "Writes.") { ran = true }
    agent = Mistri::Agent.new(provider:, tools: [tool], retries: false)

    result = agent.run("go")

    assert_predicate result, :errored?
    refute ran
    assert_empty agent.session.messages.flat_map(&:tool_calls)
    assert_empty agent.session.messages.select(&:tool?)
    assert_equal "stream ended", result.message.error_message
  end

  def test_gemini_no_id_results_never_cross_a_same_name_approval_boundary
    calls = [
      Mistri::ToolCall.new(id: "risk", name: "write", arguments: { "risk" => true }),
      Mistri::ToolCall.new(id: "safe", name: "write", arguments: { "risk" => false })
    ]
    turn = Mistri::Message.assistant(
      tool_calls: calls, provider: :gemini, stop_reason: Mistri::StopReason::TOOL_USE
    )
    provider = ScriptedProvider.new(turn, text_turn("done"))
    ran = []
    tool = Mistri::Tool.define(
      "write", "Writes.", needs_approval: ->(arguments) { arguments["risk"] },
                          schema: -> { boolean :risk, "Risky", required: true }
    ) do |arguments|
      ran << arguments["risk"]
      "written"
    end
    agent = Mistri::Agent.new(provider:, tools: [tool], max_concurrency: 1)

    result = agent.run("go")
    results = agent.session.messages.select(&:tool?)

    assert_predicate result, :completed?
    assert_equal [false], ran
    assert_empty agent.session.open_approvals
    assert_equal %w[risk safe], results.map(&:tool_call_id)
    assert_predicate results.first, :tool_error?
    assert_includes results.first.text, "retry those calls separately"
  end

  def test_gemini_no_id_calls_allow_a_final_same_name_approval
    calls = [
      Mistri::ToolCall.new(id: "safe", name: "write", arguments: { "risk" => false }),
      Mistri::ToolCall.new(id: "risk", name: "write", arguments: { "risk" => true })
    ]

    state = exercise_allowed_gemini_approval(calls)

    assert_equal [false, true], state[:ran]
    assert_equal %w[safe risk], state[:results].map(&:tool_call_id)
  end

  def test_gemini_call_ids_allow_out_of_order_same_name_results
    calls = [
      Mistri::ToolCall.new(id: "risk", name: "write", arguments: { "risk" => true },
                           provider_call_id: "wire-risk"),
      Mistri::ToolCall.new(id: "safe", name: "write", arguments: { "risk" => false },
                           provider_call_id: "wire-safe")
    ]

    state = exercise_allowed_gemini_approval(calls)

    assert_equal [false, true], state[:ran]
    assert_equal %w[safe risk], state[:results].map(&:tool_call_id)
  end

  def test_abort_during_each_pre_execution_phase_interrupts_every_call
    %i[normalizer validator before_tool approval].each do |phase|
      exercise_abort_phase(phase)
    end
  end

  def test_abort_during_resume_validation_interrupts_approved_calls_without_another_turn
    state = resume_abort_scenario
    events = []

    result = state[:agent].resume(signal: state[:signal]) { |event| events << event }

    assert_resume_abort_outcome(result, state, events)
  end

  def test_abort_during_result_rewrite_interrupts_calls_waiting_to_park
    signal = Mistri::AbortSignal.new
    ran = []
    free = Mistri::Tool.define("free", "Runs now.") do
      ran << :free
      "done"
    end
    gated = Mistri::Tool.define("gated", "Waits.", needs_approval: true) do
      flunk "gated call ran"
    end
    calls = [{ name: "free", arguments: {} }, { name: "gated", arguments: {} }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }])
    after_tool = lambda do |*|
      signal.abort!(:test)
      nil
    end
    events = []
    agent = Mistri::Agent.new(provider:, tools: [free, gated], max_concurrency: 1, after_tool:)

    result = agent.run("go", signal:) { |event| events << event }

    assert_post_execution_abort(result, agent, events, ran)
  end

  private

  def exercise_allowed_gemini_approval(calls)
    turn = Mistri::Message.assistant(
      tool_calls: calls, provider: :gemini, stop_reason: Mistri::StopReason::TOOL_USE
    )
    provider = ScriptedProvider.new(turn, text_turn("done"))
    ran = []
    tool = Mistri::Tool.define(
      "write", "Writes.", needs_approval: ->(arguments) { arguments["risk"] },
                          schema: -> { boolean :risk, "Risky", required: true }
    ) do |arguments|
      ran << arguments["risk"]
      "written"
    end
    agent = Mistri::Agent.new(provider:, tools: [tool], max_concurrency: 1)
    pending = agent.run("go").pending

    assert_equal ["risk"], pending.map(&:id)
    agent.session.approve("risk")
    result = agent.resume

    assert_predicate result, :completed?
    { ran:, results: agent.session.messages.select(&:tool?) }
  end

  def duplicate_retry_scenario
    calls = [
      Mistri::ToolCall.new(id: "duplicate", name: "pay", arguments: { "amount" => 1 }),
      Mistri::ToolCall.new(id: "duplicate", name: "pay", arguments: { "amount" => 1_000 }),
      Mistri::ToolCall.new(id: "discarded-sibling", name: "pay", arguments: { "amount" => 2 })
    ]
    clean = Mistri::ToolCall.new(id: "clean", name: "pay", arguments: { "amount" => 3 })
    provider = ScriptedProvider.new(tool_turn(calls), tool_turn([clean]), text_turn("done"))
    policies = []
    ran = []
    tool = Mistri::Tool.define(
      "pay", "Pays.",
      schema: -> { integer :amount, "Amount", required: true },
      needs_approval: lambda { |args|
        policies << args["amount"]
        args["amount"] > 100
      }
    ) do |args|
      ran << args["amount"]
      "paid"
    end
    retries = Mistri::RetryPolicy.new(attempts: 1, base: 0.0)
    events = []
    agent = Mistri::Agent.new(provider:, tools: [tool], max_concurrency: 1, retries:)
    { provider:, agent:, policies:, ran:, events: }
  end

  def resume_abort_scenario
    signal = Mistri::AbortSignal.new
    touched = []
    validations = 0
    validator = lambda do |*|
      validations += 1
      touched << :validator
      signal.abort!(:test) if validations > 2
      []
    end
    approval = lambda do |*|
      touched << :approval
      true
    end
    ran = []
    tool = Mistri::Tool.define(
      "write", "Writes.", argument_validator: validator, needs_approval: approval
    ) do
      ran << :handler
      "wrote"
    end
    calls = [{ name: "write", arguments: {} }, { name: "write", arguments: {} }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }])
    agent = Mistri::Agent.new(
      provider:, tools: [tool], before_tool: ->(*) { touched << :before }
    )
    pending = agent.run("go").pending
    pending.each { |call| agent.session.approve(call.id) }
    touched.clear
    { agent:, provider:, ran:, signal:, touched: }
  end

  def assert_clean_retry_execution(result, state)
    assert_predicate result, :completed?
    assert_equal [3], state[:policies]
    assert_equal [3], state[:ran]
    assert_empty state[:agent].session.open_approvals
    assert_equal ["clean"], state[:agent].session.messages.flat_map(&:tool_calls).map(&:id)
    assert_equal ["clean"], state[:agent].session.messages.select(&:tool?).map(&:tool_call_id)
    assert_equal 3, state[:provider].requests.length
    assert_equal state[:provider].requests[0].map(&:to_h),
                 state[:provider].requests[1].map(&:to_h),
                 "a malformed attempt retries unchanged history"
  end

  def assert_malformed_attempt_not_persisted(state)
    entries = state[:agent].session.entries
    retry_entry = entries.find { |entry| entry["type"] == "retry" }
    retry_count = entries.count { |entry| entry["type"] == "retry" }
    retry_events = state[:events].count { |event| event.type == :retry }

    assert_equal "ProviderError", retry_entry.dig("error", "type")
    assert_equal 1, retry_count
    assert_equal 1, retry_events
    refute(state[:events].any? { |event| event.type == :error })
    persisted = entries.inspect

    refute_includes persisted, "duplicate"
    refute_includes persisted, "discarded-sibling"
  end

  def assert_resume_abort_outcome(result, state, events)
    assert_predicate result, :aborted?
    assert_equal [:validator], state[:touched]
    assert_empty state[:ran]
    assert_equal 1, state[:provider].requests.length
    assert_empty state[:agent].session.open_approvals
    refute(events.any? { |event| event.type == :tool_started })
    refute(events.any? { |event| event.type == :approval_needed })
    answers = state[:agent].session.messages.select(&:tool?)

    assert_equal [Mistri::ToolExecutor::INTERRUPTED] * 2, answers.map(&:text)
    assert_equal [true, true], answers.map(&:tool_error?)
  end

  def assert_post_execution_abort(result, agent, events, ran)
    assert_predicate result, :aborted?
    assert_equal [:free], ran
    assert_empty agent.session.open_approvals
    refute(events.any? { |event| event.type == :approval_needed })
    answers = agent.session.messages.select(&:tool?)

    assert_equal %w[free gated], answers.map(&:tool_name)
    assert_equal ["done", Mistri::ToolExecutor::INTERRUPTED], answers.map(&:text)
    assert_equal [false, true], answers.map(&:tool_error?)
  end

  def exercise_abort_phase(phase)
    signal = Mistri::AbortSignal.new
    phase_calls = 0
    aborting = lambda do |value = nil, *_rest|
      phase_calls += 1
      signal.abort!(:test)
      value
    end
    options, before_tool = abort_configuration(phase, aborting)
    ran = []
    tool = Mistri::Tool.define("write", "Writes.", **options) do
      ran << :handler
      "wrote"
    end
    provider = two_call_fake
    events = []
    agent = Mistri::Agent.new(provider:, tools: [tool], before_tool:)

    result = agent.run("go", signal:) { |event| events << event }

    observed = { ran:, phase_calls: }

    assert_abort_outcome(phase, result, agent, events, observed)
  end

  def assert_malformed_id_rejected(label, id)
    call = Mistri::ToolCall.new(id:, name: "write", arguments: {})

    assert_malformed_call_rejected(label, call)
  end

  def assert_malformed_call_rejected(label, call)
    provider = ScriptedProvider.new(tool_turn([call]))
    touched = []
    normalizer = lambda do |args|
      touched << :normalizer
      args
    end
    validator = lambda do |*|
      touched << :validator
      []
    end
    approval = lambda do |*|
      touched << :approval
      true
    end
    tool = Mistri::Tool.define(
      "write", "Writes.",
      argument_normalizer: normalizer,
      argument_validator: validator,
      needs_approval: approval
    ) { touched << :handler }
    events = []
    agent = Mistri::Agent.new(
      provider:, tools: [tool], retries: false,
      before_tool: ->(*) { touched << :before }
    )

    result = agent.run("go") { |event| events << event }
    message = agent.session.messages.last

    assert_predicate result, :errored?, label
    assert_empty touched, label
    assert_empty agent.session.open_approvals, label
    assert_empty agent.session.messages.flat_map(&:tool_calls), label
    assert_empty agent.session.messages.select(&:tool?), label
    assert_equal Mistri::StopReason::ERROR, message.stop_reason, label
    assert_equal "ProviderError", message.error["type"], label
    assert_equal "The provider returned malformed tool-call metadata. No tools ran.",
                 message.text, label
    assert_equal [:error], events.select(&:terminal?).map(&:type), label
    unsafe_event = events.any? do |event|
      %i[tool_started tool_result approval_needed].include?(event.type)
    end

    refute unsafe_event, label
  end

  def abort_configuration(phase, aborting)
    options = { needs_approval: true }
    before_tool = nil
    case phase
    when :normalizer then options[:argument_normalizer] = aborting
    when :validator then options[:argument_validator] = ->(*) { aborting.call([]) }
    when :before_tool then before_tool = ->(*) { aborting.call(nil) }
    when :approval then options[:needs_approval] = ->(*) { aborting.call(true) }
    end
    [options, before_tool]
  end

  def two_call_fake
    calls = [{ name: "write", arguments: {} }, { name: "write", arguments: {} }]
    Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }])
  end

  def assert_abort_outcome(phase, result, agent, events, observed)
    assert_predicate result, :aborted?, phase
    assert_equal 1, observed[:phase_calls], phase
    assert_empty observed[:ran], phase
    assert_empty result.pending, phase
    assert_empty agent.session.open_approvals, phase
    refute(events.any? { |event| event.type == :tool_started }, phase)
    refute(events.any? { |event| event.type == :approval_needed }, phase)
    answers = agent.session.messages.select(&:tool?)

    assert_equal 2, answers.length, phase
    assert_equal [true, true], answers.map(&:tool_error?), phase
    assert_equal [Mistri::ToolExecutor::INTERRUPTED] * 2, answers.map(&:text), phase
  end

  def tool_turn(calls)
    Mistri::Message.assistant(tool_calls: calls, model: "custom-1", provider: :fake,
                              usage: Mistri::Usage.zero,
                              stop_reason: Mistri::StopReason::TOOL_USE)
  end

  def text_turn(text)
    Mistri::Message.assistant(content: text, model: "custom-1", provider: :fake,
                              usage: Mistri::Usage.zero,
                              stop_reason: Mistri::StopReason::STOP)
  end
end # rubocop:enable Metrics/ClassLength
