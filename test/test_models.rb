# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

class TestModels < Minitest::Test
  def test_known_models_carry_their_output_ceiling
    assert_equal 128_000, Mistri::Models.max_output("claude-opus-4-8")
    assert_equal 64_000, Mistri::Models.max_output("claude-haiku-4-5")
  end

  def test_dated_aliases_resolve_and_unknown_ids_pass_through
    assert_equal 128_000, Mistri::Models.max_output("claude-sonnet-5-20260201")
    assert_nil Mistri::Models.find("claude-next-9000")
  end

  def test_the_provider_sends_the_model_ceiling_as_max_tokens
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "type" => "message_stop" })
      server.finish_sse(socket)
    end
    provider = Mistri::Providers::Anthropic.new(api_key: "test", origin: server.origin)

    seen = []
    provider.stream(messages: [Mistri::Message.user("hi")]) { |event| seen << event }
    body = JSON.parse(server.requests.first[:body])

    assert_equal 128_000, body["max_tokens"]
    assert_equal "claude-opus-4-8", body["model"]
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, body["thinking"])
  ensure
    provider&.close
    server&.stop
  end
end
