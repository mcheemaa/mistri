# frozen_string_literal: true

require_relative "test_helper"

# transform_context is an ephemeral lens: it reshapes what the model sees on
# each turn while the stored transcript stays untouched.
class TestTransformContext < Minitest::Test
  REMINDER = "Reminder: the brand color is sapphire."

  def test_the_transform_shapes_the_wire_but_not_the_session
    provider = Mistri::Providers::Fake.new(turns: [{ text: "ok" }])
    agent = Mistri::Agent.new(provider:, transform_context: append_reminder)

    agent.run("write the tagline")

    sent = provider.requests.last[:messages]

    assert_equal REMINDER, sent.last.text
    refute(agent.session.messages.any? { |m| m.text == REMINDER },
           "the reminder never persists")
  end

  def test_the_transform_applies_fresh_every_turn
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "noop", arguments: {} }] },
                                             { text: "done" }
                                           ])
    noop = Mistri::Tool.define("noop", "Does nothing.") { "ok" }
    agent = Mistri::Agent.new(provider:, tools: [noop], transform_context: append_reminder)

    agent.run("go")

    provider.requests.each do |request|
      reminders = request[:messages].count { |m| m.text == REMINDER }

      assert_equal 1, reminders, "exactly one reminder per request, always at the tail"
    end
  end

  private

  def append_reminder
    ->(messages) { messages + [Mistri::Message.user(REMINDER)] }
  end
end
