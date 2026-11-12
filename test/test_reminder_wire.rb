# frozen_string_literal: true

require_relative "test_helper"

# A reminder is a system message in the conversation. Anthropic sends it as a
# system message where the model takes one in the middle of a conversation,
# OpenAI as a developer message, and every other case as text of a user turn
# in a system-reminder block. No other system message of the conversation is
# sent.
class TestReminderWire < Minitest::Test
  LIST = "<system-reminder>\nThe list.\n</system-reminder>"
  MORE = "<system-reminder>\nMore.\n</system-reminder>"

  def history
    [Mistri::Message.user("Go."), Mistri::Message.system("A host's own."),
     Mistri::Message.reminder("deferred_tools", "The list.", "More.")]
  end

  def test_anthropic_sends_a_reminder_as_text_of_a_user_turn
    wire = Mistri::Providers::Anthropic::Serializer.messages(history)

    assert_equal [{ role: "user", content: [{ type: "text", text: "Go." }] },
                  { role: "user", content: [{ type: "text", text: LIST },
                                            { type: "text", text: MORE }] }], wire
  end

  ANTHROPIC = Mistri::Providers::Anthropic::Serializer
  NOTE = { role: "system", content: [{ type: "text", text: "The list." },
                                     { type: "text", text: "More." }] }.freeze

  def roles(messages)
    ANTHROPIC.messages(messages, system_messages: true).map { |turn| turn[:role] }
  end

  def test_anthropic_sends_a_reminder_as_a_system_message_where_the_model_takes_one
    assert_equal [{ role: "user", content: [{ type: "text", text: "Go." }] }, NOTE],
                 ANTHROPIC.messages(history, system_messages: true)
  end

  def test_anthropic_places_a_system_message_after_a_user_turn_and_before_the_assistant_turn
    user, _, reminder = history
    call = Mistri::ToolCall.new(id: "call_1", name: "lookup", arguments: {})
    asked = Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use)
    result = Mistri::Message.tool(content: "Order 7.", tool_call_id: "call_1", tool_name: "lookup")
    answer = Mistri::Message.assistant(content: "Done.", stop_reason: :stop)

    assert_equal %w[user user system], roles([user, reminder, user])
    assert_equal %w[user system assistant user], roles([user, reminder, answer, user])
    assert_equal %w[user assistant user system], roles([user, asked, result, reminder])
    assert_equal %w[user assistant user system assistant],
                 roles([user, asked, reminder, result, answer])
    assert_equal %w[user assistant user], roles([user, answer, reminder])
    assert_equal [{ type: "text", text: LIST }, { type: "text", text: MORE }],
                 ANTHROPIC.messages([user, answer, reminder], system_messages: true).last[:content]
  end

  def test_anthropic_keeps_the_results_of_one_turn_together_around_a_system_message
    user, plain, reminder = history
    calls = %w[a b].map { |id| Mistri::ToolCall.new(id:, name: "tool_search", arguments: {}) }
    asked = Mistri::Message.assistant(tool_calls: calls, stop_reason: :tool_use)
    first, second = { "a" => "x", "b" => "y" }.map do |id, tool|
      Mistri::Message.tool(content: "Loaded: #{tool}.", tool_call_id: id,
                           tool_name: "tool_search", loads: [tool])
    end
    together = ["user", %w[tool_result tool_result text text]]

    { [plain, false] => [], [plain, true] => [], [reminder, false] => [["user", %w[text text]]],
      [reminder, true] => [["system", %w[text text]]] }.each do |(between, native), after|
      wire = ANTHROPIC.messages([user, asked, first, between, second],
                                deferred: %w[x y], system_messages: native)
      turns = wire.drop(2).map { |turn| [turn[:role], turn[:content].map { |block| block[:type] }] }

      assert_equal [together, *after], turns
    end
  end

  def test_anthropic_marks_the_user_turn_before_a_system_message_for_the_cache
    wire = ANTHROPIC.messages(history, system_messages: true, cache: true)

    assert_equal({ type: "ephemeral" }, wire.first[:content].last[:cache_control])
    assert_equal NOTE, wire.last
  end

  def test_anthropic_takes_a_system_message_from_these_models_on
    takes = %w[claude-fable-5-2 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-fable-5
               claude-opus-5 claude-opus-4-8 claude-opus-4-8-20260101 claude-opus-6]
    refuses = %w[claude-opus-4-7 claude-sonnet-5 claude-sonnet-5-20260101 claude-sonnet-4-6
                 claude-haiku-4-5 claude-3-5-sonnet-20241022 gpt-6.1-terra]

    assert(takes.all? { |id| Mistri::Models.system_messages?(id) })
    assert(refuses.none? { |id| Mistri::Models.system_messages?(id) })
  end

  # Records the request bodies a provider builds, and sends nothing.
  class Recorded
    def bodies = @bodies ||= []

    def stream_post(_path, body:, **)
      bodies << body
      :done
    end

    def close = nil
  end

  def test_the_anthropic_provider_sends_a_system_message_to_a_model_that_takes_one
    official = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-haiku-5-5")
    gateway = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-haiku-5-5",
                                               origin: "https://gateway.example")
    sent = Recorded.new
    [official, gateway].each { |provider| provider.instance_variable_set(:@transport, sent) }

    official.stream(messages: history)
    official.stream(messages: history, model: "claude-opus-4-7")
    gateway.stream(messages: history)

    assert_equal(%w[system user user], sent.bodies.map { |body| body[:messages].last[:role] })
    assert_predicate official, :system_messages?
    refute official.system_messages?("claude-opus-4-7")
    refute_predicate gateway, :system_messages?
  end

  def test_openai_sends_a_reminder_as_text_of_a_user_turn
    wire = Mistri::Providers::OpenAI::Serializer.input_items(history)

    assert_equal [{ role: "user", content: [{ type: "input_text", text: "Go." }] },
                  { role: "user", content: [{ type: "input_text", text: LIST },
                                            { type: "input_text", text: MORE }] }], wire
  end

  def test_openai_sends_a_reminder_as_a_developer_message_where_the_conversation_holds_it
    user = history.first
    serializer = Mistri::Providers::OpenAI::Serializer
    wire = serializer.input_items([*history, user], system_messages: true)

    assert_equal [{ role: "user", content: [{ type: "input_text", text: "Go." }] },
                  { role: "developer", content: [{ type: "input_text", text: "The list." },
                                                 { type: "input_text", text: "More." }] },
                  { role: "user", content: [{ type: "input_text", text: "Go." }] }], wire
  end

  def test_the_openai_provider_sends_a_developer_message_on_its_own_origin
    official = Mistri::Providers::OpenAI.new(api_key: "k", model: "gpt-5-nano")
    gateway = Mistri::Providers::OpenAI.new(api_key: "k", origin: "https://gateway.example")
    sent = Recorded.new
    [official, gateway].each { |provider| provider.instance_variable_set(:@transport, sent) }

    official.stream(messages: history)
    gateway.stream(messages: history)

    assert_equal(%w[developer user], sent.bodies.map { |body| body[:input].last[:role] })
    assert_predicate official, :system_messages?
    refute_predicate gateway, :system_messages?
  end

  def test_gemini_has_no_system_message_in_a_conversation
    gemini = Mistri::Providers::Gemini.new(api_key: "k")

    refute_predicate gemini, :system_messages?
  ensure
    gemini&.close
  end

  def test_gemini_sends_a_reminder_as_text_of_a_user_turn
    wire = Mistri::Providers::Gemini::Serializer.contents(history)

    assert_equal [{ role: "user", parts: [{ text: "Go." }] },
                  { role: "user", parts: [{ text: LIST }, { text: MORE }] }], wire
  end

  def test_a_provider_of_the_host_s_own_is_given_a_reminder_as_a_user_turn
    refund = Mistri::Tool.define("refund_charge", "Refunds.", deferred: true) { "ran" }
    own = Class.new do
      def initialize(fake) = @fake = fake
      def model = @fake.model
      def stream(...) = @fake.stream(...)
    end
    takes = Class.new(own) { def system_messages? = true }
    declines = Class.new(own) { def system_messages? = false }
    { own => :user, declines => :user, takes => :system }.each do |provider_class, role|
      fake = Mistri::Providers::Fake.new(turns: [{ text: "Done." }])
      agent = Mistri::Agent.new(provider: provider_class.new(fake), tools: [refund])

      agent.run("Refund it.")
      given = fake.requests.first[:messages]
      note = given.find { |message| message.text.include?("refund_charge") }

      assert_equal role, note.role
      assert_equal role == :system, given.any?(&:system?)
      assert_predicate agent.session.messages.find(&:reminder), :system?
    end
  end

  def test_an_agent_keeps_the_results_of_one_turn_together_on_a_model_without_system_messages
    provider = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-4-7")
    sent = Recorded.new
    provider.instance_variable_set(:@transport, sent)
    tools = %w[x y].map { |name| Mistri::Tool.define(name, "Does #{name}.", deferred: true) { name } }
    calls = %w[a b].map { |id| Mistri::ToolCall.new(id:, name: "tool_search", arguments: {}) }
    results = { "a" => "x", "b" => "y" }.map do |id, tool|
      Mistri::Message.tool(content: "Loaded: #{tool}.", tool_call_id: id,
                           tool_name: "tool_search", loads: [tool])
    end
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    [Mistri::Message.user("Go."),
     Mistri::Message.assistant(tool_calls: calls, stop_reason: :tool_use), *results]
      .each { |message| session.append_message(message) }
    between = lambda do |messages|
      messages.dup.insert(messages.index(&:tool?) + 1, Mistri::Message.reminder("probe", "Stop."))
    end

    Mistri::Agent.new(provider:, session:, tools:, transform_context: between, retries: false)
                 .run("Go on.")
    turns = sent.bodies.first[:messages].map { |turn| turn[:content].map { |block| block[:type] } }

    assert_equal [%w[tool_result tool_result text text], %w[text]], turns[2, 2]
  end
end
