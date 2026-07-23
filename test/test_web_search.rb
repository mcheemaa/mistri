# frozen_string_literal: true

require_relative "test_helper"

class TestWebSearch < Minitest::Test
  def test_web_search_returns_a_frozen_shared_value
    assert_instance_of Mistri::WebSearch, Mistri.web_search
    assert_predicate Mistri.web_search, :frozen?
    assert_same Mistri.web_search, Mistri.web_search
  end

  def test_server_tool_call_round_trips_through_content
    call = Mistri::Content::ServerToolCall.new(
      id: "srvtoolu_1", name: "web_search",
      arguments: { "query" => "ruby 3.4 release date" }
    )

    restored = Mistri::Content.from_h(JSON.parse(JSON.generate(call.to_h)))

    assert_equal call, restored
    assert_equal :server_tool_call, restored.type
  end

  def test_server_tool_result_round_trips_through_content
    result = Mistri::Content::ServerToolResult.new(
      tool_call_id: "srvtoolu_1", name: "web_search",
      payload: [{ "type" => "web_search_result", "url" => "https://ruby-lang.org" }]
    )

    restored = Mistri::Content.from_h(JSON.parse(JSON.generate(result.to_h)))

    assert_equal result, restored
    assert_equal :server_tool_result, restored.type
  end

  def test_server_tool_call_signature_survives_the_round_trip
    call = Mistri::Content::ServerToolCall.new(id: "ws_1", name: "web_search",
                                               arguments: {}, signature: "{\"raw\":1}")

    restored = Mistri::Content.from_h(call.to_h)

    assert_equal "{\"raw\":1}", restored.signature
  end

  def test_server_tool_calls_are_not_executable_tool_calls
    message = Mistri::Message.assistant(content: [
                                          Mistri::Content::ServerToolCall.new(
                                            id: "ws_1", name: "web_search", arguments: {}
                                          )
                                        ])

    assert_empty message.tool_calls
    refute_predicate message, :tool_calls?
  end

  def test_agent_passes_web_search_to_the_provider_without_executing_it
    provider = Mistri::Providers::Fake.new(turns: [{ text: "hi" }])
    agent = Mistri::Agent.new(provider: provider, tools: [Mistri.web_search])

    result = agent.run("hello")

    assert_equal :completed, result.status
    assert_includes provider.requests.first[:options][:tools], Mistri.web_search
  end
end
