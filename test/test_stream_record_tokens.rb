# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

# How many JSON tokens one stream record may hold before it is parsed. The
# count bounds what a record can allocate. A stream that echoes its request
# gets as many more tokens as the request had bytes.
class TestStreamRecordTokens < Minitest::Test
  def test_a_stream_that_echoes_its_request_may_spend_as_many_more_tokens_as_it_had_bytes
    body = { "pad" => "x" * 1_000 }
    limit = 20_001 + JSON.generate(body).bytesize
    widths = [limit, limit + 1, limit]
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, wide_record(widths[server.requests.length - 1]))
      server.finish_sse(socket)
    end
    transport = Mistri::Transport.new(origin: server.origin)
    records = []

    transport.stream_post("/v1/x", body:, echoes_request: true) { |record| records << record }
    over = assert_raises(Mistri::ResponseTooComplexError) do
      transport.stream_post("/v1/x", body:, echoes_request: true) { flunk }
    end
    plain = assert_raises(Mistri::ResponseTooComplexError) do
      transport.stream_post("/v1/x", body:) { flunk }
    end

    assert_equal [wide_record(limit)], records
    assert_equal [:sse_record_tokens, limit], [over.kind, over.limit]
    assert_equal [:sse_record_tokens, 20_001], [plain.kind, plain.limit]
  ensure
    teardown_all(transport, server)
  end

  def test_a_streamable_http_answer_with_too_many_tokens_is_still_refused
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "tools" => Array.new(20_002, 0) })
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

  def test_a_stream_that_echoes_its_request_still_bounds_depth_and_numbers
    lines = ["data: #{"[" * 70}#{"]" * 70}\n\n", "data: {\"value\":#{"1" * 65_537}}\n\n"]
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.chunk(socket, lines[server.requests.length - 1])
      server.finish_sse(socket)
    end
    transport = Mistri::Transport.new(origin: server.origin)

    kinds = Array.new(2) do
      assert_raises(Mistri::ResponseTooComplexError) do
        transport.stream_post("/v1/x", body: {}, echoes_request: true) { flunk }
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

  def test_openai_answering_a_small_request_with_a_wide_record_is_refused
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "type" => "response.created",
                                "response" => { "tools" => Array.new(30_000) { {} } } })
      server.finish_sse(socket)
    end
    provider = Mistri::Providers::OpenAI.new(api_key: "test", model: "gpt-6.1-sol",
                                             origin: server.origin)

    result = Mistri::Agent.new(provider:).run("go")
    sent = server.requests.first[:body].bytesize

    assert_predicate result, :errored?
    assert_equal({ "type" => "ResponseTooComplexError", "kind" => "sse_record_tokens",
                   "limit" => 20_001 + sent }, result.message.error)
  ensure
    provider&.close
    server&.stop
  end

  def test_openai_tool_arguments_keep_their_own_token_limit
    item = { "type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "wide" }
    wide = JSON.generate("values" => Array.new(20_002, 0))
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "type" => "response.output_item.added", "item" => item })
      server.sse_data(socket, { "type" => "response.output_item.done",
                                "item" => item.merge("arguments" => wide) })
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

  def test_gemini_tool_arguments_wider_than_the_guard_allows_still_end_the_turn
    arguments = Array.new(20_002, 0)
    call = { "functionCall" => { "name" => "search", "args" => { "values" => arguments } } }
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

  # A record with exactly this many JSON tokens: the object, its key, the
  # array and one token for each number in it.
  def wide_record(tokens) = { "tools" => Array.new(tokens - 3, 0) }

  def teardown_all(transport, server)
    transport&.close
    server&.stop
  end
end
