# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

# A Gemini 4 model returns at most 65,536 tokens for one request. An answer
# that needs more ends its request with CONTINUATION and a token, and the
# same request sent again with the token goes on in the middle of a sentence.
class TestGeminiContinuation < Minitest::Test
  ASSEMBLER = Mistri::Providers::Gemini::Assembler

  def teardown
    @provider&.close
    @server&.stop
  end

  def test_two_requests_join_into_one_text_with_their_usage_added_up
    events = []
    emit = ->(event) { events << event }
    assembler = ASSEMBLER.new(model: "gemini-4-argon")
    first_request.each { |record| assembler.feed(record, &emit) }

    assert_equal "token-1", assembler.continue
    second_request.each { |record| assembler.feed(record, &emit) }

    assert_nil assembler.continue
    message = assembler.finish(&emit)

    assert_equal ["A sum is the first part and the rest."], message.content.map(&:text)
    assert_equal :stop, message.stop_reason
    assert_equal [156 + 2_156, 2_000 + 40, 156 + 2_040],
                 [message.usage.prompt_tokens, message.usage.output, message.usage.context_tokens]
    assert_predicate message.usage.cost, :known?
    assert_in_delta ((156 + 2_156) * 2.0 / 1e6) + (2_040 * 10.0 / 1e6), message.usage.cost.total
    assert_equal %i[text_start text_end], events.map(&:type).grep(/text_(start|end)/)
  end

  def test_an_answer_of_one_request_has_no_token_and_no_context_of_its_own
    assembler = ASSEMBLER.new(model: "gemini-4-argon")
    second_request.each { |record| assembler.feed(record) }

    assert_nil assembler.continue
    assert_nil assembler.finish.usage.context
  end

  def test_a_last_request_that_reports_no_usage_states_no_context
    assembler = ASSEMBLER.new(model: "gemini-4-argon")
    first_request.each { |record| assembler.feed(record) }
    assembler.continue
    assembler.feed({ "candidates" => [{ "content" => { "parts" => [{ "text" => " more" }] },
                                        "finishReason" => "STOP" }] })
    usage = assembler.finish.usage

    assert_nil usage.context
    assert_equal 156 + 2_000, usage.context_tokens
    refute_predicate usage.cost, :known?
  end

  def test_a_signed_part_is_not_merged_with_the_text_that_goes_on_after_it
    assembler = ASSEMBLER.new(model: "gemini-4-argon")
    signed = [{ "candidates" => [{ "content" => { "parts" => [
      { "text" => "A sum is", "thoughtSignature" => "sig-1" }
    ] }, "finishReason" => "CONTINUATION", "continuationToken" => "token-1" }] }]
    signed.each { |record| assembler.feed(record) }
    assembler.continue
    second_request.each { |record| assembler.feed(record) }
    message = assembler.finish

    assert_equal ["A sum is", " and the rest."], message.content.map(&:text)
    assert_equal ["sig-1", nil], message.content.map(&:signature)
    assert_equal "A sum is and the rest.", message.text
  end

  def test_an_answer_that_is_to_go_on_with_no_token_fails_as_a_provider_error
    assembler = ASSEMBLER.new(model: "gemini-4-argon")
    assembler.feed({ "candidates" => [{ "content" => { "parts" => [{ "text" => "cut" }] },
                                        "finishReason" => "CONTINUATION" }] })

    assert_nil assembler.continue
    message = assembler.finish

    assert_equal :error, message.stop_reason
    assert_match(/carried no token/, message.error_message)
    assert Mistri::RetryPolicy.new.retryable?(message.error)
  end

  def test_an_answer_does_not_go_on_for_ever
    assembler = ASSEMBLER.new(model: "gemini-4-argon")
    hop = { "candidates" => [{ "content" => { "parts" => [{ "text" => "." }] },
                               "finishReason" => "CONTINUATION",
                               "continuationToken" => "again" }] }
    tokens = Array.new(ASSEMBLER::MAX_REQUESTS) do
      assembler.feed(hop)
      assembler.continue
    end

    assert_equal (["again"] * (ASSEMBLER::MAX_REQUESTS - 1)) + [nil], tokens
    message = assembler.finish

    assert_match(/went on past 32 requests/, message.error_message)
    refute Mistri::RetryPolicy.new.retryable?(message.error)
  end

  def test_the_provider_sends_the_same_request_again_with_the_token
    replies = [first_request, second_request]
    @server = Mistri::Test::StubServer.new do |socket, _request|
      @server.start_sse(socket)
      replies.shift.each { |record| @server.sse_data(socket, record) }
      @server.finish_sse(socket)
    end
    @provider = Mistri::Providers::Gemini.new(api_key: "k", model: "gemini-4-argon",
                                              origin: @server.origin, max_tokens: 100_000)

    message = @provider.stream(messages: [Mistri::Message.user("Explain a sum.")],
                               system: "Be exact.")
    first, second = @server.requests.map { |request| JSON.parse(request[:body]) }

    assert_equal "A sum is the first part and the rest.", message.text
    assert_equal 100_000, first.dig("generationConfig", "maxOutputTokens")
    refute first.key?("continuationToken")
    assert_equal first.merge("continuationToken" => "token-1"), second
  end

  def test_a_cancelled_answer_does_not_go_on
    requests = 0
    signal = Mistri::AbortSignal.new
    @server = Mistri::Test::StubServer.new do |socket, _request|
      requests += 1
      @server.start_sse(socket)
      first_request.each { |record| @server.sse_data(socket, record) }
      signal.abort!
      @server.finish_sse(socket)
    end
    @provider = Mistri::Providers::Gemini.new(api_key: "k", model: "gemini-4-argon",
                                              origin: @server.origin, max_tokens: 100_000)

    message = @provider.stream(messages: [Mistri::Message.user("Explain a sum.")], signal:)

    assert_equal :aborted, message.stop_reason
    assert_equal 1, requests
  end

  def test_a_stream_call_can_set_another_output_limit_than_the_provider
    @provider = Mistri::Providers::Gemini.new(api_key: "k", max_tokens: 100_000)
    history = [Mistri::Message.user("hi")]

    assert_equal 100_000, @provider.send(:build_body, history, nil, [], {})
                                   .dig(:generationConfig, :maxOutputTokens)
    assert_equal 8_192, @provider.send(:build_body, history, nil, [], { max_tokens: 8_192 })
                                 .dig(:generationConfig, :maxOutputTokens)
    plain = Mistri::Providers::Gemini.new(api_key: "k")

    refute plain.send(:build_body, history, nil, [], {})[:generationConfig]
                .key?(:maxOutputTokens)
  ensure
    plain&.close
  end

  private

  def first_request
    [{ "candidates" => [{ "content" => { "parts" => [{ "text" => "A sum is " }] } }] },
     { "candidates" => [{ "content" => { "parts" => [{ "text" => "the first part" }] },
                          "finishReason" => "CONTINUATION", "continuationToken" => "token-1" }],
       "usageMetadata" => { "promptTokenCount" => 156, "candidatesTokenCount" => 400,
                            "thoughtsTokenCount" => 1_600 } }]
  end

  def second_request
    [{ "candidates" => [{ "content" => { "parts" => [{ "text" => " and the rest." }] } }] },
     { "candidates" => [{ "finishReason" => "STOP" }],
       "usageMetadata" => { "promptTokenCount" => 2_156, "candidatesTokenCount" => 40 } }]
  end
end
