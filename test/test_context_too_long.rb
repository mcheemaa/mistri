# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/stub_server"

# A request longer than the model's context window: each provider gives its
# refusal one type, the agent compacts once and sends the turn again, and a
# part to summarize that fits no single request is read in parts.
class TestContextTooLong < Minitest::Test
  TOO_LONG = { error: "prompt is too long", error_type: "ContextTooLongError", status: 400 }.freeze
  REFUSALS = {
    Mistri::Providers::Anthropic => [
      [400, { "type" => "error", "error" => { "type" => "invalid_request_error",
                                              "message" => "prompt is too long: 213462 tokens > " \
                                                           "200000 maximum" } }],
      [413, { "type" => "error", "error" => { "type" => "request_too_large",
                                              "message" => "Request exceeds the maximum size" } }]
    ],
    Mistri::Providers::Gemini => [
      [400, { "error" => { "code" => 400, "status" => "INVALID_ARGUMENT",
                           "message" => "The input token count (1196265) exceeds the maximum " \
                                        "number of tokens allowed (1048575)." } }]
    ]
  }.freeze

  def teardown
    @provider&.close
    @server&.stop
  end

  def test_each_provider_gives_its_refusal_of_a_long_input_one_type
    REFUSALS.each do |provider, refusals|
      refusals.each do |status, body|
        error = refused(provider, status, body).error

        assert_equal ["ContextTooLongError", status], error.values_at("type", "status")
        assert Mistri::ErrorData.too_long?(error)
      end
    end
  end

  def test_openai_s_refusal_inside_a_stream_has_the_type
    failure = { "type" => "invalid_request_error", "code" => "context_length_exceeded",
                "message" => "Your input exceeds the context window of this model." }
    @server = Mistri::Test::StubServer.new do |socket, _request|
      @server.start_sse(socket)
      @server.sse_data(socket, { "type" => "error", **failure })
      @server.sse_data(socket, { "type" => "response.failed",
                                 "response" => { "status" => "failed", "error" => failure } })
      @server.finish_sse(socket)
    end
    @provider = Mistri::Providers::OpenAI.new(api_key: "k", origin: @server.origin)

    reply = @provider.stream(messages: [Mistri::Message.user("go")])

    assert_equal({ "type" => "ContextTooLongError" }, reply.error)
    assert_includes reply.error_message, "context_length_exceeded"
  end

  def test_another_refusal_keeps_its_type
    other = { "error" => { "type" => "invalid_request_error", "message" => "bad schema" } }

    [*REFUSALS.keys, Mistri::Providers::OpenAI].each do |provider|
      error = refused(provider, 400, other).error

      assert_equal "ProviderError", error["type"]
      refute Mistri::ErrorData.too_long?(error)
    end
    refute Mistri::ErrorData.too_long?(nil)
    assert_same :kept, Mistri::ContextTooLongError.from(:kept) { true }
  end

  def test_a_refused_turn_is_compacted_once_and_sent_again
    provider = Mistri::Providers::Fake.new(turns: [TOO_LONG, { text: "Summary." },
                                                   { text: "Answer." }])
    agent = Mistri::Agent.new(provider:, session: history, compaction: settings, retries: nil)
    events = []

    result = agent.run("the question") { |event| events << event }
    kinds = events.map(&:type) & %i[compacting compaction retry error done]
    stored = agent.session.entries

    assert_predicate result, :completed?
    assert_equal "Answer.", result.text
    assert_equal %i[compacting compaction retry done], kinds
    assert_equal(%i[overflow overflow], events.select { |e| e.type.to_s.start_with?("compact") }
                                             .map(&:reason))
    assert_equal "overflow", agent.session.last_compaction["trigger"]
    assert_equal({ "type" => "ContextTooLongError", "status" => 400 },
                 stored.find { |entry| entry["type"] == "retry" }["error"])
    assert(stored.none? { |entry| entry.dig("message", "stop_reason") == "error" })
    assert_includes provider.requests.last[:messages].first.text, "Summary."
  end

  def test_a_second_refusal_ends_the_run_with_the_error
    provider = Mistri::Providers::Fake.new(turns: [TOO_LONG, { text: "Summary." }, TOO_LONG])
    agent = Mistri::Agent.new(provider:, session: history, compaction: settings)

    result = agent.run("the question")

    assert_equal :error, result.message.stop_reason
    assert_equal 3, provider.requests.length
    assert_equal(1, agent.session.entries.count { |entry| entry["type"] == "compaction" })
  end

  def test_the_refusal_stands_with_no_compaction_and_with_nothing_to_compact
    off = Mistri::Providers::Fake.new(turns: [TOO_LONG])
    small = Mistri::Providers::Fake.new(turns: [TOO_LONG])
    bare = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    stopped = Mistri::Agent.new(provider: off, session: history, compaction: false).run("go")
    short = Mistri::Agent.new(provider: small, session: bare, compaction: settings).run("go")

    assert_equal(%i[error error], [stopped, short].map { |result| result.message.stop_reason })
    assert_equal([1, 1], [off, small].map { |provider| provider.requests.length })
  end

  def test_a_failed_compaction_leaves_the_refusal_and_is_not_tried_for_ever
    turns = Array.new(4) { [TOO_LONG, { error: "overloaded" }] }.flatten(1)
    provider = Mistri::Providers::Fake.new(turns: turns.first(7))
    session = history
    agent = Mistri::Agent.new(provider:, session:, compaction: settings, retries: nil)

    results = Array.new(4) { agent.run("go") }

    assert(results.all? { |result| result.message.stop_reason == :error })
    assert_equal 7, provider.requests.length
    assert_equal 3, session.compaction_failures(trigger: :overflow)
  end

  def test_a_compaction_the_provider_refuses_as_too_long_is_asked_as_text
    refusal = Mistri::Providers::Fake.new(turns: [TOO_LONG]).stream
    provider = TestNativeCompaction::Compacting.new(native: refusal, turns: [{ text: "Summary." }])
    agent = Mistri::Agent.new(provider:, session: history, compaction: settings)
    events = []

    agent.compact { |event| events << event }

    assert_equal 1, provider.requests.length, "the conversation itself was not asked"
    assert provider.requests.first[:messages].first.text.start_with?("<conversation>")
    assert_equal [:own, "prompt is too long"], events.last.to_h.values_at(:status, :error_message)
  end

  def test_a_conversation_refused_as_too_long_is_asked_as_text
    provider = Mistri::Providers::Fake.new(turns: [TOO_LONG, { text: "Summary." }])
    agent = Mistri::Agent.new(provider:, session: history, compaction: settings)

    result = agent.compact
    first, second = provider.requests.map { |request| request[:messages] }

    assert_equal "Summary.", result[:summary]
    assert_equal Mistri::Compactor::CLOSING_CHECKPOINT_PROMPT, first.last.text
    assert second.first.text.start_with?("<conversation>")
  end

  def test_a_text_that_fits_no_request_is_read_in_parts_that_update_one_summary
    provider = Mistri::Providers::Fake.new(turns: [{ text: "One." }, { text: "Two." },
                                                   { text: "Three." }])
    session = history(turns: 8)

    result = Mistri::Compactor.call(session:, provider:, settings: settings(window: 3_100))
    texts = provider.requests.map { |request| request[:messages].first.text }

    assert_equal "Three.", result[:summary]
    assert_equal 3, texts.length
    assert texts.first.end_with?(Mistri::Compactor::CHECKPOINT_PROMPT)
    assert_includes texts[1], "<previous-summary>\nOne.\n</previous-summary>"
    assert_includes texts[2], "<previous-summary>\nTwo.\n</previous-summary>"
    assert_equal (1..7).map { |n| "question #{n} " }, texts.join.scan(/question \d /).uniq
    assert(texts.all? { |text| text.length / 4.0 <= 2_100 })
  end

  def test_a_part_the_provider_still_refuses_is_halved_and_a_failure_ends_the_parts
    provider = Mistri::Providers::Fake.new(turns: [TOO_LONG, { text: "One." }, { text: "Two." }])
    session = history(turns: 5)

    result = Mistri::Compactor.call(session:, provider:, settings:)
    counts = provider.requests.map { |asked| asked[:messages].first.text.scan(/^USER:$/).length }

    assert_equal "Two.", result[:summary]
    assert_equal [4, 2, 2], counts

    alone = Mistri::Providers::Fake.new(turns: [TOO_LONG, { text: "One." }, *([TOO_LONG] * 3)])
    error = assert_raises(Mistri::CompactionError) do
      Mistri::Compactor.call(session: history(turns: 4), provider: alone, settings:)
    end

    assert_includes error.message, "prompt is too long"
    assert_equal 5, alone.requests.length
  end

  private

  def settings(**) = Mistri::Compaction.new(keep_recent: 10, max_tokens: 1_000, reserve: 1_000, **)

  def history(turns: 3)
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    (1..turns).each do |n|
      session.append_message(Mistri::Message.user("question #{n} #{"word " * 150}"))
      session.append_message(Mistri::Message.assistant(content: "answer #{n} #{"word " * 150}",
                                                       stop_reason: :stop))
    end
    session
  end

  def refused(provider, status, body)
    @server&.stop
    @provider&.close
    @server = Mistri::Test::StubServer.new do |socket, _request|
      @server.respond_json(socket, body, status:)
    end
    @provider = provider.new(api_key: "k", origin: @server.origin)
    @provider.stream(messages: [Mistri::Message.user("go")])
  end
end
