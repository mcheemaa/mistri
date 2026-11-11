# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

# The count of JSON tokens in one stream record, taken before the record is
# parsed. It is kept where it bounds something: Gemini's tool arguments, which
# arrive as an object inside the record, and an MCP server's answer. An OpenAI
# or Anthropic record is not counted.
class TestStreamRecordTokens < Minitest::Test
  WIDE = { "pad" => Array.new(20_002, 0) }.freeze

  def test_the_count_covers_every_kind_of_token_and_can_be_left_out
    scanner = Mistri.const_get(:ToolArguments, false)
    kinds = { "strings" => '""', "arrays" => "[]", "numbers" => "0",
              "true" => "true", "false" => "false", "null" => "null" }

    kinds.each do |kind, token|
      wide = "[#{Array.new(20_002, token).join(",")}]"

      assert_equal "too_many_nodes", scanner.raw_json_resource_error(wide), kind
      assert_nil scanner.raw_json_resource_error(wide, count_tokens: false), kind
    end
  end

  def test_a_stream_counts_the_tokens_in_a_record_only_when_asked
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, WIDE)
      server.finish_sse(socket)
    end
    transport = Mistri::Transport.new(origin: server.origin)
    records = []

    transport.stream_post("/v1/x", body: {}) { |record| records << record }
    error = assert_raises(Mistri::ResponseTooComplexError) do
      transport.stream_post("/v1/x", body: {}, count_tokens: true) { flunk }
    end

    assert_equal [WIDE], records
    assert_equal [:sse_record_tokens, 20_001], [error.kind, error.limit]
  ensure
    teardown_all(transport, server)
  end

  def test_a_streamable_http_answer_with_too_many_tokens_is_refused
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, WIDE)
      server.finish_sse(socket)
    end
    transport = Mistri::Transport.new(origin: server.origin)

    error = assert_raises(Mistri::ResponseTooComplexError) do
      transport.post_either("/mcp", body: {}) { flunk }
    end

    assert_equal :sse_record_tokens, error.kind
  ensure
    teardown_all(transport, server)
  end

  def test_a_stream_that_does_not_count_tokens_still_bounds_depth_and_numbers
    lines = ["data: #{"[" * 70}#{"]" * 70}\n\n", "data: {\"value\":#{"1" * 65_537}}\n\n"]
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.chunk(socket, lines[server.requests.length - 1])
      server.finish_sse(socket)
    end
    transport = Mistri::Transport.new(origin: server.origin)

    kinds = Array.new(2) do
      assert_raises(Mistri::ResponseTooComplexError) do
        transport.stream_post("/v1/x", body: {}) { flunk }
      end.kind
    end

    assert_equal %i[sse_record_depth sse_numeric_token], kinds
  ensure
    teardown_all(transport, server)
  end

  def test_openai_echoing_a_large_tool_list_does_not_end_the_run
    server = Mistri::Test::StubServer.new do |socket, request|
      server.start_sse(socket)
      server.sse_data(socket, { "type" => "response.created",
                                "response" => { "tools" => JSON.parse(request[:body])["tools"] } })
      server.sse_data(socket, { "type" => "response.completed",
                                "response" => { "status" => "completed", "usage" => {} } })
      server.finish_sse(socket)
    end
    provider = Mistri::Providers::OpenAI.new(api_key: "test", model: "gpt-6.1-sol",
                                             origin: server.origin)
    fields = lambda do
      8.times { |n| string :"field_#{n}", "Field #{n}", required: true }
    end
    tools = Array.new(400) do |n|
      Mistri::Tool.define("tool_#{n}", "Does thing #{n}.", schema: fields) { "ok" }
    end

    result = Mistri::Agent.new(provider:, tools:).run("go")

    refute_predicate result, :errored?
    assert_equal 400, JSON.parse(server.requests.first[:body])["tools"].length
  ensure
    provider&.close
    server&.stop
  end

  def test_an_anthropic_record_is_not_counted
    message = anthropic_reply(
      { "type" => "ping" }.merge(WIDE),
      { "type" => "content_block_start", "index" => 0,
        "content_block" => { "type" => "text", "text" => "" } },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "text_delta", "text" => "ready" } },
      { "type" => "content_block_stop", "index" => 0 },
      { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" } }
    )

    assert_equal [:stop, "ready"], [message.stop_reason, message.text]
  end

  def test_anthropic_tool_arguments_keep_their_own_token_limit
    block = { "type" => "tool_use", "id" => "toolu_1", "name" => "wide", "input" => {} }
    message = anthropic_reply(
      { "type" => "content_block_start", "index" => 0, "content_block" => block },
      { "type" => "content_block_delta", "index" => 0,
        "delta" => { "type" => "input_json_delta", "partial_json" => JSON.generate(WIDE) } },
      { "type" => "content_block_stop", "index" => 0 },
      { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" } }
    )
    call = message.tool_calls.first

    assert_equal %w[wide too_many_nodes], [call.name, call.arguments_error]
  end

  def test_anthropic_tool_arguments_that_arrive_as_an_object_are_never_run
    block = { "type" => "tool_use", "id" => "toolu_1", "name" => "wide", "input" => WIDE }
    message = anthropic_reply(
      { "type" => "content_block_start", "index" => 0, "content_block" => block },
      { "type" => "content_block_stop", "index" => 0 },
      { "type" => "message_delta", "delta" => { "stop_reason" => "tool_use" } }
    )

    assert_equal :error, message.stop_reason
    assert_empty message.tool_calls
  end

  def test_openai_tool_arguments_keep_their_own_token_limit
    item = { "type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "wide" }
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "type" => "response.output_item.added", "item" => item })
      server.sse_data(socket, { "type" => "response.output_item.done",
                                "item" => item.merge("arguments" => JSON.generate(WIDE)) })
      server.sse_data(socket, { "type" => "response.completed",
                                "response" => { "status" => "completed", "usage" => {} } })
      server.finish_sse(socket)
    end
    provider = Mistri::Providers::OpenAI.new(api_key: "test", model: "gpt-6.1-sol",
                                             origin: server.origin)

    call = provider.stream(messages: [Mistri::Message.user("go")]).tool_calls.first

    assert_equal %w[wide too_many_nodes], [call.name, call.arguments_error]
  ensure
    provider&.close
    server&.stop
  end

  def test_gemini_tool_arguments_wider_than_the_count_allows_end_the_turn
    call = { "functionCall" => { "name" => "search", "args" => WIDE } }
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "candidates" => [{ "content" => { "parts" => [call] } }] })
      server.finish_sse(socket)
    end
    provider = Mistri::Providers::Gemini.new(api_key: "test", origin: server.origin)

    result = Mistri::Agent.new(provider:).run("go")

    assert_predicate result, :errored?
    assert_equal %w[ResponseTooComplexError sse_record_tokens],
                 result.message.error.values_at("type", "kind")
  ensure
    provider&.close
    server&.stop
  end

  private

  def anthropic_reply(*events)
    events = [{ "type" => "message_start", "message" => { "id" => "msg_1" } }, *events,
              { "type" => "message_stop" }]
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      events.each { |event| server.sse_data(socket, event) }
      server.finish_sse(socket)
    end
    provider = Mistri::Providers::Anthropic.new(api_key: "test", origin: server.origin)
    provider.stream(messages: [Mistri::Message.user("go")])
  ensure
    provider&.close
    server&.stop
  end

  def teardown_all(transport, server)
    transport&.close
    server&.stop
  end
end
