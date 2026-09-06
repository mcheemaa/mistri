# frozen_string_literal: true

require "securerandom"
require_relative "test_helper"

# Fable's prefix-bound thinking must survive compaction as durable history,
# without sending an invalid signature back in the shortened replay.
class TestFableCompactionLive < Minitest::Test
  SYSTEM = "Follow the user's instructions exactly. " \
           "Use lookup_checkpoint before stating its value."

  # Older accounts do not enforce binding by default; explicitly opt in so
  # this regression exercises the same rejection as newly created accounts.
  class BindingCheckedTransport
    def initialize(transport)
      @transport = transport
    end

    def stream_post(path, body:, headers:, **, &emit)
      headers = headers.merge("anthropic-beta" => "thinking-binding-controls-2026-08-01")
      thinking = body.fetch(:thinking).merge(block_binding: { prefix_mismatch_behavior: "error" })
      @transport.stream_post(path, body: body.merge(thinking:), headers:, **, &emit)
    end

    def close = @transport.close
  end

  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?

    @provider = Mistri::Providers::Anthropic.new(
      api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: "claude-fable-5-1", read_timeout: 120
    )
    transport = BindingCheckedTransport.new(@provider.instance_variable_get(:@transport))
    @provider.instance_variable_set(:@transport, transport)
    @tools = [{ name: "lookup_checkpoint", description: "Returns the checkpoint value.",
                input_schema: { type: "object", properties: { prime: { type: "integer" } },
                                required: ["prime"] } }]
  end

  def teardown
    @provider&.close
  end

  def test_signed_tool_thinking_replays_after_compaction_and_a_later_turn
    session = checkpoint_session
    reply = signed_tool_reply(session.messages)
    call = reply.tool_calls.first
    secret = "checkpoint-#{SecureRandom.hex(12)}"
    session.append_message(reply)
    session.append_message(Mistri::Message.tool(
                             content: "CHECKPOINT_VALUE=#{secret}\n" \
                                      "Return CHECKPOINT_VALUE exactly.",
                             tool_call_id: call.id, tool_name: call.name
                           ))

    assert_completed_value(session.messages, secret)
    durable = session.entries

    compaction = Mistri::Compactor.call(session:, provider: @provider,
                                        settings: Mistri::Compaction.new(keep_recent: 100))

    refute_nil compaction, "the fixture must cross a real compaction boundary"
    assert_operator session.last_compaction.fetch("kept_from"), :>, 0
    retained = session.messages.find { |message| message.tool_calls.include?(call) }

    refute_nil retained, "the signed tool-call turn must remain in the compacted tail"
    assert_empty retained.content.grep(Mistri::Content::Thinking)
    assert_equal durable, session.entries.take(durable.length), "the durable history changed"

    continued = assert_completed_value(session.messages, secret)
    session.append_message(continued)

    assert_equal continued, session.messages.last, "new post-compaction thinking must remain intact"

    session.append_message(Mistri::Message.user(
                             "Repeat the checkpoint value exactly, without calling a tool."
                           ))

    assert_completed_value(session.messages, secret)
  end

  private

  def checkpoint_session
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user(
                             "Earlier task: verify a synthetic migration. " * 50
                           ))
    session.append_message(Mistri::Message.assistant(
                             content: "Earlier preparation is complete. " * 50, stop_reason: :stop
                           ))
    session.append_message(Mistri::Message.user(
                             "Determine the smallest prime larger than 1000000. " \
                             "Check its divisibility carefully. Then call lookup_checkpoint " \
                             "with that prime once, without answering in text first."
                           ))
    session
  end

  def signed_tool_reply(messages)
    reply = stream(messages)

    assert_equal :tool_use, reply.stop_reason, reply.error_message
    assert_equal 1, reply.tool_calls.length
    assert_equal "lookup_checkpoint", reply.tool_calls.first.name
    assert(reply.content.grep(Mistri::Content::Thinking).any? do |block|
      !block.signature.to_s.empty?
    end, "the tool turn must carry real signed thinking to exercise prefix binding")
    reply
  end

  def assert_completed_value(messages, secret)
    reply = stream(messages)

    assert_equal :stop, reply.stop_reason, reply.error_message
    assert_includes reply.text, secret
    reply
  end

  def stream(messages)
    Mistri::Test.retry_transient do
      @provider.stream(messages:, system: SYSTEM, tools: @tools)
    end
  end
end
