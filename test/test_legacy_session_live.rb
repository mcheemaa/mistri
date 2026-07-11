# frozen_string_literal: true

require_relative "test_helper"
require "securerandom"

# A literal pre-0.6 repeated-ID history must remain a valid continuation on
# every provider, not merely pass Mistri's local audit.
class TestLegacySessionLive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
  end

  def test_anthropic_accepts_a_legacy_repeated_id_continuation
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?

    with_provider(Mistri::Providers::Anthropic.new(
                    api_key: ENV.fetch("ANTHROPIC_API_KEY")
                  )) { |provider| assert_legacy_continuation(provider) }
  end

  def test_openai_accepts_a_legacy_repeated_id_continuation
    skip "no OPENAI_API_KEY" if ENV["OPENAI_API_KEY"].to_s.empty?

    with_provider(Mistri::Providers::OpenAI.new(
                    api_key: ENV.fetch("OPENAI_API_KEY")
                  )) { |provider| assert_legacy_continuation(provider) }
  end

  private

  def with_provider(provider)
    yield provider
  ensure
    provider.close
  end

  def assert_legacy_continuation(provider)
    first = "first-#{SecureRandom.hex(4)}"
    second = "second-#{SecureRandom.hex(4)}"
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    append_exchange(session, provider: :fake, result: first)
    append_exchange(session, provider: :gemini, result: second)
    session.append_message(Mistri::Message.user(
                             "Return both exact historical tool results separated by one space."
                           ))

    message = provider.stream(messages: session.messages) { |_event| nil }

    assert_equal :stop, message.stop_reason
    assert_includes message.text, first
    assert_includes message.text, second
  end

  def append_exchange(session, provider:, result:)
    call = Mistri::ToolCall.new(id: "call_1", name: "lookup", arguments: {})
    session.append_message(Mistri::Message.assistant(tool_calls: [call], provider:,
                                                     stop_reason: :tool_use))
    session.append_message(Mistri::Message.tool(content: result, tool_call_id: call.id,
                                                tool_name: call.name))
  end
end
