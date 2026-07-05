# frozen_string_literal: true

require_relative "test_helper"

# Reminders ride transform_context: due by completed assistant turns, fresh
# on the wire, never in the session.
class TestReminder < Minitest::Test
  def turn(count)
    messages = [Mistri::Message.user("go")]
    count.times { messages << Mistri::Message.assistant(content: "step", stop_reason: :stop) }
    messages
  end

  def test_due_on_the_interval_after_the_lead_in
    reminder = Mistri::Reminder.every(3, "Focus.")

    refute_equal reminder.call(turn(0)).last.text, reminder_body, "never before a turn ran"
    refute reminded?(reminder, 2)
    assert reminded?(reminder, 3)
    refute reminded?(reminder, 4)
    assert reminded?(reminder, 6)
  end

  def test_after_overrides_the_lead_in
    reminder = Mistri::Reminder.every(3, "Focus.", after: 1)

    assert reminded?(reminder, 1)
    assert reminded?(reminder, 4)
    refute reminded?(reminder, 3)
  end

  def test_the_reminder_reaches_the_wire_but_never_the_session
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "noop", arguments: {} }] },
                                             { text: "done" }
                                           ])
    noop = Mistri::Tool.define("noop", "N.") { "ok" }
    agent = Mistri::Agent.new(provider:, tools: [noop],
                              transform_context: Mistri::Reminder.every(1, "Stay sharp."))

    agent.run("go")

    second_request = provider.requests.last[:messages]

    assert(second_request.any? { |m| m.text.to_s.include?("Stay sharp.") })
    refute(agent.session.messages.any? { |m| m.text.to_s.include?("Stay sharp.") })
  end

  def test_transforms_chain_in_order
    stamp = ->(messages) { messages + [Mistri::Message.user("stamped")] }
    upcase_tail = lambda do |messages|
      messages[0..-2] + [Mistri::Message.user(messages.last.text.upcase)]
    end
    provider = Mistri::Providers::Fake.new(turns: [{ text: "ok" }])
    agent = Mistri::Agent.new(provider:, transform_context: [stamp, upcase_tail])

    agent.run("go")

    assert_equal "STAMPED", provider.requests.last[:messages].last.text
  end

  private

  def reminder_body = "<system-reminder>\nFocus.\n</system-reminder>"

  def reminded?(reminder, turns)
    reminder.call(turn(turns)).last.text == reminder_body
  end
end
