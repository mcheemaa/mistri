# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

# On OpenAI the request's tools stay as they are and a result that loads
# tools is followed by an additional_tools item, which makes them callable
# from that point in the input on. The cached prefix is not touched.
class TestOpenAIDeferredTools < Minitest::Test
  SERIALIZER = Mistri::Providers::OpenAI::Serializer

  def spec(name) = { name:, description: "Does #{name}.", input_schema: { "type" => "object" } }

  def call(id, name) = Mistri::ToolCall.new(id:, name:, arguments: {})

  def calling(*calls) = Mistri::Message.assistant(tool_calls: calls, stop_reason: :tool_use)

  def result(id, name: "tool_search", loads: nil, content: "Loaded.", **)
    Mistri::Message.tool(content:, tool_call_id: id, tool_name: name, loads:, **)
  end

  def types(items) = items.map { |item| item[:type] || item[:role] }

  def deferred = [spec("create_issue"), spec("list_teams")]

  def teardown
    @provider&.close
    @server&.stop
  end

  def test_a_result_that_loads_tools_is_followed_by_their_definitions
    history = [Mistri::Message.user("go"), calling(call("c1", "tool_search")),
               result("c1", loads: %w[create_issue list_teams])]

    items = SERIALIZER.input_items(history, deferred:)

    assert_equal %w[user function_call function_call_output additional_tools], types(items)
    assert_equal "developer", items.last[:role]
    assert_equal [{ type: "function", name: "create_issue", description: "Does create_issue.",
                    parameters: { "type" => "object" }, strict: false },
                  { type: "function", name: "list_teams", description: "Does list_teams.",
                    parameters: { "type" => "object" }, strict: false }], items.last[:tools]
  end

  def test_only_a_deferred_tool_is_declared_and_only_once
    history = [Mistri::Message.user("go"), calling(call("c1", "tool_search")),
               result("c1", loads: %w[create_issue retired]),
               calling(call("c2", "tool_search")),
               result("c2", loads: %w[create_issue list_teams]),
               calling(call("c3", "tool_search")), result("c3", loads: %w[retired])]

    items = SERIALIZER.input_items(history, deferred:)
    added = items.select { |item| item[:type] == "additional_tools" }

    assert_equal([%w[create_issue], %w[list_teams]],
                 added.map { |item| item[:tools].map { |tool| tool[:name] } })
    assert_equal "function_call_output", items.last[:type]
  end

  def test_a_call_to_a_tool_declared_before_it_carries_the_namespace
    history = [Mistri::Message.user("go"), calling(call("c0", "create_issue")),
               result("c0", name: "create_issue", content: "Created."),
               calling(call("c1", "tool_search")), result("c1", loads: %w[create_issue]),
               calling(call("c2", "create_issue"), call("c3", "lookup")),
               result("c2", name: "create_issue", content: "Created."),
               result("c3", name: "lookup", content: "None.")]

    calls = SERIALIZER.input_items(history, deferred:)
                      .select { |item| item[:type] == "function_call" }

    assert_equal([["create_issue", nil], ["tool_search", nil],
                  %w[create_issue create_issue], ["lookup", nil]],
                 calls.map { |item| [item[:name], item[:namespace]] })
  end

  def test_each_definition_follows_its_own_result_when_two_calls_share_a_turn
    history = [Mistri::Message.user("go"),
               calling(call("c1", "tool_search"), call("c2", "tool_search")),
               result("c1", loads: %w[create_issue]), result("c2", loads: %w[list_teams])]

    items = SERIALIZER.input_items(history, deferred:)

    assert_equal %w[user function_call function_call function_call_output additional_tools
                    function_call_output additional_tools], types(items)
  end

  def test_a_failed_result_declares_nothing
    history = [Mistri::Message.user("go"), calling(call("c1", "tool_search")),
               result("c1", loads: %w[create_issue], tool_error: true)]

    items = SERIALIZER.input_items(history, deferred:)

    assert_equal %w[user function_call function_call_output], types(items)
  end

  def test_a_request_without_deferred_tools_is_as_before
    history = [Mistri::Message.user("go"), calling(call("c1", "tool_search")),
               result("c1", loads: %w[create_issue]), calling(call("c2", "create_issue"))]

    items = SERIALIZER.input_items(history)

    assert_equal %w[user function_call function_call_output function_call], types(items)
    refute items.last.key?(:namespace)
  end

  def test_models_from_five_point_four_on_hold_definitions_back_and_nano_models_do_not
    loading = %w[gpt-5.4 gpt-5.4-2026-03-05 gpt-5.4-mini gpt-5.5 gpt-5.6 gpt-5.6-luna gpt-6-astra
                 gpt-6.1-terra gpt-7 gpt-10.2-sol]
    growing = %w[gpt-5-nano gpt-5.4-nano gpt-5.4-nano-2026-03-17 gpt-6-nano gpt-5 gpt-5-mini
                 gpt-5.3 gpt-4.1 gpt-4.1-2025-04-14 gpt-4o o4-mini a-model-from-next-year]

    assert_equal(loading, loading.select { |model| Mistri::Models.tool_loading?(model) })
    assert_empty(growing.select { |model| Mistri::Models.tool_loading?(model) })
  end

  def test_the_provider_holds_definitions_back_for_such_a_model_on_the_official_origin
    answers = %w[gpt-6.1-terra gpt-5-nano gpt-4.1].to_h do |model|
      provider = Mistri::Providers::OpenAI.new(api_key: "k", model:)
      [model, provider.defers_tools?].tap { provider.close }
    end
    other = Mistri::Providers::OpenAI.new(api_key: "k", origin: "https://gateway.example")

    assert_equal({ "gpt-6.1-terra" => true, "gpt-5-nano" => false, "gpt-4.1" => false }, answers)
    refute_predicate other, :defers_tools?
  ensure
    other&.close
  end

  def test_a_name_repeated_in_one_result_is_declared_once
    history = [Mistri::Message.user("go"), calling(call("c1", "tool_search")),
               result("c1", loads: %w[create_issue create_issue list_teams create_issue]),
               calling(call("c2", "tool_search")), result("c2", loads: %w[create_issue])]

    added = SERIALIZER.input_items(history, deferred:)
                      .select { |item| item[:type] == "additional_tools" }

    assert_equal([%w[create_issue list_teams]],
                 added.map { |item| item[:tools].map { |tool| tool[:name] } })
  end

  def test_the_request_keeps_its_tools_and_carries_the_loaded_ones_in_the_input
    @server = Mistri::Test::StubServer.new do |socket, _request|
      @server.start_sse(socket)
      @server.sse_data(socket, { "type" => "response.completed",
                                 "response" => { "status" => "completed", "output" => [] } })
      @server.finish_sse(socket)
    end
    @provider = Mistri::Providers::OpenAI.new(api_key: "k", origin: @server.origin)
    history = [Mistri::Message.user("go"), calling(call("c1", "tool_search")),
               result("c1", loads: %w[create_issue])]

    @provider.stream(messages: history, tools: [spec("tool_search")], deferred_tools: deferred)
    body = JSON.parse(@server.requests.first[:body])

    assert_equal(%w[tool_search], body["tools"].map { |tool| tool["name"] })
    assert_equal(%w[create_issue], body["input"].last["tools"].map { |tool| tool["name"] })
    refute body.key?("deferred_tools")
  end
end
