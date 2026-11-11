# frozen_string_literal: true

require_relative "test_helper"

# A budget with wrap_up gives the model one tool-free turn to answer the user
# when a ceiling stops the run.
class TestBudgetWrapUp < Minitest::Test
  LOOP_CALL = { tool_calls: [{ name: "loop", arguments: {} }] }.freeze
  TOOL_SPEC = { name: "loop", description: "Loops.",
                input_schema: { type: "object", properties: {} } }.freeze

  def test_wrap_up_is_off_unless_asked_for
    refute_predicate Mistri::Budget.new(turns: 2), :wrap_up?
    assert_predicate Mistri::Budget.new(turns: 2, wrap_up: true), :wrap_up?
  end

  def test_a_budget_stop_ends_with_the_models_answer
    provider, agent = stopped_run({ text: "Two files checked, one left." })

    result = agent.run("go")

    assert_predicate result, :stopped_by_budget?
    assert_equal "Two files checked, one left.", result.text
    assert_equal :budget, result.stop_reason
    assert_equal "budget_turns", result.error_message
    assert_equal result.message, agent.session.messages.last
    assert_equal 3, provider.requests.length
  end

  def test_the_wrap_up_turn_keeps_the_tools_and_forbids_calling_them
    provider, agent = stopped_run({ text: "Done so far." })

    agent.run("go")

    earlier, final = provider.requests.last(2).map { |request| request[:options] }

    assert_equal :none, final[:tool_choice]
    assert_equal earlier[:tools], final[:tools]
    refute earlier.key?(:tool_choice)
  end

  # A tool setting with no tools declared is a request the APIs reject.
  def test_an_agent_without_tools_wraps_up_without_a_tool_setting
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Nothing started." }])
    agent = Mistri::Agent.new(provider:, budget: Mistri::Budget.new(turns: 0, wrap_up: true))

    result = agent.run("go")

    assert_equal "Nothing started.", result.text
    refute provider.requests.last[:options].key?(:tool_choice)
  end

  def test_the_wrap_up_instruction_reaches_the_model_and_not_the_session
    provider, agent = stopped_run({ text: "Done so far." })

    agent.run("go")

    sent = provider.requests.last[:messages].last

    assert_predicate sent, :user?
    refute_empty sent.text.strip
    refute_includes agent.session.messages, sent
    assert_raises(NameError) { Mistri::Agent::WRAP_UP }
  end

  def test_the_wrap_up_turn_answers_a_steer_sent_during_the_last_tool_batch
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    tool = Mistri::Tool.define("loop", "Loops.") do
      session.steer("Only check the EU region.")
      "again"
    end
    provider = Mistri::Providers::Fake.new(turns: [LOOP_CALL, { text: "EU checked." }])
    agent = Mistri::Agent.new(provider:, tools: [tool], session:,
                              budget: Mistri::Budget.new(turns: 1, wrap_up: true))

    agent.run("go")

    assert_includes provider.requests.last[:messages].map(&:text), "Only check the EU region."
    assert_empty session.pending_inbox
  end

  def test_a_task_wraps_up_without_its_schema
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Counted 3 of 5 files." }])
    agent = Mistri::Agent.new(provider:, budget: Mistri::Budget.new(turns: 0, wrap_up: true))
    schema = { type: "object", properties: { count: { type: "integer" } }, required: ["count"] }

    result = agent.task("Count the files.", schema:)

    assert_equal "Counted 3 of 5 files.", result.text
    assert_nil result.output
    assert_nil provider.requests.last[:options][:output_schema]
  end

  def test_a_failed_wrap_up_turn_falls_back_to_the_fixed_message
    _, agent = stopped_run({ error: "overloaded" })

    result = agent.run("go")

    assert_predicate result, :stopped_by_budget?
    assert_equal "Run stopped: turns budget reached.", result.text
    assert_equal result.message, agent.session.messages.last
  end

  def test_tool_calls_in_a_wrap_up_answer_are_never_saved
    _, agent = stopped_run({ text: "Partial answer.", tool_calls: LOOP_CALL[:tool_calls] })

    result = agent.run("go")

    assert_equal "Partial answer.", result.text
    assert_empty result.tool_calls
    assert_empty agent.session.messages.last.tool_calls
  end

  def test_a_wrap_up_answer_with_only_tool_calls_falls_back_to_the_fixed_message
    _, agent = stopped_run(LOOP_CALL)

    result = agent.run("go")

    assert_equal "Run stopped: turns budget reached.", result.text
    assert_empty agent.session.messages.last.tool_calls
  end

  # Its signature covers the instruction, which the session never replays.
  def test_a_prefix_bound_wrap_up_answer_is_saved_without_its_thinking
    _, agent = stopped_run({ thinking: "Weighing it.", text: "Done so far." },
                           provider: PrefixBoundFake)

    agent.run("go")

    assert_equal [Mistri::Content::Text], agent.session.messages.last.content.map(&:class)
  end

  def test_a_wrap_up_answer_from_another_provider_keeps_its_thinking
    _, agent = stopped_run({ thinking: "Weighing it.", text: "Done so far." })

    agent.run("go")

    assert_equal [Mistri::Content::Thinking, Mistri::Content::Text],
                 agent.session.messages.last.content.map(&:class)
  end

  def test_every_built_in_provider_forbids_tool_calls_in_its_own_field
    openai = Mistri::Providers::OpenAI.new(api_key: "k")
    gemini = Mistri::Providers::Gemini.new(api_key: "k")
    anthropic = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-5-5")
    history = [Mistri::Message.user("hello")]
    overrides = { tool_choice: :none }

    openai_body = openai.send(:build_body, "gpt-6.1-sol", history, nil, [TOOL_SPEC], overrides)
    gemini_body = gemini.send(:build_body, history, nil, [TOOL_SPEC], overrides)
    anthropic_body = anthropic.send(:build_body, "claude-opus-5-5", history, nil, [TOOL_SPEC],
                                    overrides)

    assert_equal "none", openai_body[:tool_choice]
    assert_equal "NONE", gemini_body.dig(:toolConfig, :functionCallingConfig, :mode)
    assert_equal({ type: "none" }, anthropic_body[:tool_choice])
    assert([openai_body, gemini_body, anthropic_body].all? { |body| body[:tools].any? })
  ensure
    [openai, gemini, anthropic].compact.each(&:close)
  end

  # Answers as a model whose thinking signs every earlier message.
  class PrefixBoundFake < Mistri::Providers::Fake
    def stream(...) = super.with(provider: :anthropic, model: "claude-opus-5-5")
  end

  private

  # Two tool turns spend a two-turn budget; final_turn scripts the wrap-up.
  def stopped_run(final_turn, provider: Mistri::Providers::Fake)
    provider = provider.new(turns: [LOOP_CALL, LOOP_CALL, final_turn])
    tool = Mistri::Tool.define("loop", "Loops.") { "again" }
    agent = Mistri::Agent.new(provider:, tools: [tool], retries: nil,
                              budget: Mistri::Budget.new(turns: 2, wrap_up: true))
    [provider, agent]
  end
end
