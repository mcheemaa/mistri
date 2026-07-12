# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/stub_server"

# Provider subscribers cannot become provider, transport, or parse failures.
class TestSubscriberProviderBoundaries < Minitest::Test
  def test_every_network_provider_propagates_a_start_subscriber_error
    providers = [
      Mistri::Providers::Anthropic.new(api_key: "test", origin: "http://127.0.0.1:1"),
      Mistri::Providers::OpenAI.new(api_key: "test", origin: "http://127.0.0.1:1"),
      Mistri::Providers::Gemini.new(api_key: "test", origin: "http://127.0.0.1:1")
    ]

    providers.each do |provider|
      failure = Mistri::RateLimitError.new("subscriber failed")
      events = []
      raised = assert_raises(Mistri::RateLimitError, provider.class.name) do
        provider.stream(messages: [Mistri::Message.user("hello")]) do |event|
          events << event.type
          raise failure
        end
      end

      assert_same failure, raised
      assert_equal [:start], events
    ensure
      provider.close
    end
  end

  def test_agent_does_not_retry_a_subscriber_rate_limit_error
    provider = Mistri::Providers::Anthropic.new(api_key: "test",
                                                origin: "http://127.0.0.1:1")
    retries = Mistri::RetryPolicy.new(attempts: 1, base: 0, max_delay: 0)
    agent = Mistri::Agent.new(provider:, retries:)
    failure = Mistri::RateLimitError.new("subscriber failed")
    events = []

    raised = assert_raises(Mistri::RateLimitError) do
      agent.run("hello") do |event|
        events << event.type
        raise failure if event.type == :start
      end
    end

    assert_same failure, raised
    assert_equal 1, events.count(:start)
    refute_includes events, :retry
    assert_empty(agent.session.entries.select { |entry| entry["type"] == "retry" })
    assert_empty agent.session.messages.select(&:assistant?)
  ensure
    provider&.close
  end

  def test_a_genuine_provider_failure_still_returns_an_error_turn
    server = error_server
    provider = anthropic_provider(server)
    events = []

    message = provider.stream(messages: [Mistri::Message.user("hello")]) do |event|
      events << event.type
    end

    assert_equal :error, message.stop_reason
    assert_equal "ServerError", message.error.fetch("type")
    assert_equal %i[start error], events
  ensure
    provider&.close
    server&.stop
  end

  def test_midstream_subscriber_failures_are_not_transport_or_parse_failures
    server = anthropic_server
    provider = anthropic_provider(server)
    failures = [IOError.new("io subscriber"),
                Timeout::Error.new("timeout subscriber"),
                JSON::ParserError.new("json subscriber"),
                Mistri::ConfigurationError.new("mistri subscriber")]

    failures.each do |failure|
      raised = assert_raises(failure.class) do
        provider.stream(messages: [Mistri::Message.user("hello")]) do |event|
          raise failure if event.type == :text_delta
        end
      end

      assert_same failure, raised
    end

    message = provider.stream(messages: [Mistri::Message.user("hello")])

    assert_equal "hello", message.text
    assert_equal 5, server.requests.length
    assert_equal 5, server.accepts, "each interrupted body closed its connection"
  ensure
    provider&.close
    server&.stop
  end

  def test_json_parser_error_from_a_direct_sse_subscriber_is_not_swallowed
    failure = JSON::ParserError.new("subscriber failed")
    sse = Mistri::SSE.new

    raised = assert_raises(JSON::ParserError) do
      sse.feed("data: {\"ok\":true}\n\n") { raise failure }
    end

    assert_same failure, raised
  end

  def test_an_inline_child_cannot_unwrap_its_parent_subscriber_failure
    server = anthropic_server
    child_provider = anthropic_provider(server)
    child = Mistri::SubAgent.new(name: "researcher", description: "Researches.",
                                 provider: child_provider)
    parent = Mistri::Providers::Fake.new(turns: [
                                           { tool_calls: [{ name: "researcher",
                                                            arguments: { task: "research" } }] }
                                         ])
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    agent = Mistri::Agent.new(provider: parent, tools: [child.tool], session:)
    failure = IOError.new("subscriber failed")

    raised = assert_raises(IOError) do
      agent.run("delegate") do |event|
        raise failure if event.origin && event.type == :text_delta
      end
    end

    assert_same failure, raised
    assert_empty persisted_tool_entries(session)
    child_id = session.entries.find { |entry| entry["type"] == "subagent" }.fetch("session_id")
    child_session = Mistri::Session.new(store:, id: child_id)
    terminal = child_session.entries.find { |entry| entry["type"] == Mistri::Child::TERMINAL }

    assert_equal "failed", terminal["status"]
    assert_equal "IOError: subscriber failed", terminal["error"]
  ensure
    child_provider&.close
    server&.stop
  end

  private

  def persisted_tool_entries(session)
    session.entries.select do |entry|
      entry["type"] == "message" && entry.dig("message", "role") == "tool"
    end
  end

  def anthropic_server
    Mistri::Test::StubServer.new do |socket, _request|
      payload = anthropic_records.map { |record| "data: #{JSON.generate(record)}\n\n" }.join
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                   "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
    end
  end

  def anthropic_provider(server)
    Mistri::Providers::Anthropic.new(api_key: "test", origin: server.origin,
                                     model: "claude-haiku-4-5-20251001")
  end

  def error_server
    Mistri::Test::StubServer.new do |socket, _request|
      payload = JSON.generate("error" => "unavailable")
      socket.write("HTTP/1.1 503 Unavailable\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
    end
  end

  def anthropic_records
    [
      { "type" => "message_start", "message" => { "usage" => { "input_tokens" => 1 } } },
      { "type" => "content_block_start", "index" => 0,
        "content_block" => { "type" => "text" } },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "text_delta", "text" => "hello" } },
      { "type" => "content_block_stop", "index" => 0 },
      { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
        "usage" => { "output_tokens" => 1 } },
      { "type" => "message_stop" }
    ]
  end
end
