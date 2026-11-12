# frozen_string_literal: true

require_relative "test_helper"

# A reminder is a system message in the conversation. Each provider sends it
# as text of a user turn in a system-reminder block, and sends no other
# system message of the conversation.
class TestReminderWire < Minitest::Test
  LIST = "<system-reminder>\nThe list.\n</system-reminder>"
  MORE = "<system-reminder>\nMore.\n</system-reminder>"

  def history
    [Mistri::Message.user("Go."), Mistri::Message.system("A host's own."),
     Mistri::Message.reminder("deferred_tools", "The list.", "More.")]
  end

  def test_anthropic_sends_a_reminder_as_text_of_a_user_turn
    wire = Mistri::Providers::Anthropic::Serializer.messages(history)

    assert_equal [{ role: "user", content: [{ type: "text", text: "Go." }] },
                  { role: "user", content: [{ type: "text", text: LIST },
                                            { type: "text", text: MORE }] }], wire
  end

  def test_openai_sends_a_reminder_as_text_of_a_user_turn
    wire = Mistri::Providers::OpenAI::Serializer.input_items(history)

    assert_equal [{ role: "user", content: [{ type: "input_text", text: "Go." }] },
                  { role: "user", content: [{ type: "input_text", text: LIST },
                                            { type: "input_text", text: MORE }] }], wire
  end

  def test_gemini_sends_a_reminder_as_text_of_a_user_turn
    wire = Mistri::Providers::Gemini::Serializer.contents(history)

    assert_equal [{ role: "user", parts: [{ text: "Go." }] },
                  { role: "user", parts: [{ text: LIST }, { text: MORE }] }], wire
  end
end
