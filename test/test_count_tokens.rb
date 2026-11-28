# frozen_string_literal: true

require_relative "test_helper"

# Each provider's own count of a request: the body that stream would send,
# cut down to what the count endpoint takes, and posted to it.
class TestCountTokens < Minitest::Test
  class Endpoint
    attr_reader :calls

    def initialize(answer)
      @answer = answer
      @calls = []
    end

    def post(path, body:, headers: {})
      @calls << { path:, body:, headers: }
      @answer
    end

    def close; end
  end

  HISTORY = [Mistri::Message.user("hello")].freeze
  TOOL = Mistri::Tool.define("read", "Reads a note.") { "" }.spec

  def test_anthropic_counts_the_body_of_a_request_without_its_stream_settings
    provider = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-5-5")
    endpoint = swap(provider, "input_tokens" => 44)

    count = provider.count_tokens(messages: HISTORY, system: "Be exact.", tools: [TOOL],
                                  max_tokens: 100, temperature: 0.2, tool_choice: { type: "auto" })
    call = endpoint.calls.first

    assert_equal 44, count
    assert_equal "/v1/messages/count_tokens", call[:path]
    assert_equal %i[messages model system thinking tool_choice tools], call[:body].keys.sort
    assert_equal "claude-opus-5-5", call[:body][:model]
    assert_equal Mistri::Providers::Anthropic::BINDING_BETA, call[:headers]["anthropic-beta"]
  end

  def test_openai_counts_the_input_the_tools_and_the_reasoning_setting
    provider = Mistri::Providers::OpenAI.new(api_key: "k", model: "gpt-6.2-sol")
    endpoint = swap(provider, "input_tokens" => 31, "object" => "response.input_tokens")

    count = provider.count_tokens(messages: HISTORY, system: "Be exact.", tools: [TOOL],
                                  max_tokens: 100)
    call = endpoint.calls.first

    assert_equal 31, count
    assert_equal "/v1/responses/input_tokens", call[:path]
    assert_equal %i[input model reasoning tools], call[:body].keys.sort
    assert_equal(%w[developer user], call[:body][:input].map { |item| item[:role] })
  end

  def test_gemini_counts_a_whole_request_with_its_system_instruction_and_tools
    provider = Mistri::Providers::Gemini.new(api_key: "k", model: "gemini-4-argon",
                                             max_tokens: 100_000)
    endpoint = swap(provider, "totalTokens" => 27)

    count = provider.count_tokens(messages: HISTORY, system: "Be exact.", tools: [TOOL])
    call = endpoint.calls.first
    request = call[:body].fetch(:generateContentRequest)

    assert_equal 27, count
    assert_equal "/v1beta/models/gemini-4-argon:countTokens", call[:path]
    assert_equal %i[contents model systemInstruction tools], request.keys.sort
    assert_equal "models/gemini-4-argon", request[:model]
  end

  def test_a_stream_call_can_count_for_another_model
    provider = Mistri::Providers::Gemini.new(api_key: "k")
    endpoint = swap(provider, "totalTokens" => 5)

    provider.count_tokens(messages: HISTORY, model: "gemini-4-neon")

    assert_equal "/v1beta/models/gemini-4-neon:countTokens", endpoint.calls.first[:path]
  end

  def test_another_origin_is_not_asked_to_count
    [Mistri::Providers::Anthropic, Mistri::Providers::OpenAI,
     Mistri::Providers::Gemini].each do |provider_class|
      provider = provider_class.new(api_key: "k", origin: "https://gateway.example")
      endpoint = swap(provider, {})

      assert_nil provider.count_tokens(messages: HISTORY)
      assert_empty endpoint.calls
    end
  end

  private

  def swap(provider, answer)
    provider.close
    endpoint = Endpoint.new(answer)
    provider.instance_variable_set(:@transport, endpoint)
    endpoint
  end
end
