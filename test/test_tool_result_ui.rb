# frozen_string_literal: true

require_relative "test_helper"

# Two-channel tool results: content reaches the model, ui reaches only the
# host — on the event, in the store, and never on a provider's wire.
class TestToolResultUi < Minitest::Test
  MARKER = "UI_ONLY_PAYLOAD_9Z"

  def test_content_reaches_the_model_and_ui_reaches_the_host
    store = Mistri::Stores::Memory.new
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "edit_page", arguments: {} }] },
                                             { text: "done" }
                                           ])
    tool = Mistri::Tool.define("edit_page", "Edits.") do
      Mistri::ToolResult.new(content: "Updated the hero.",
                             ui: { html: "<h1>#{MARKER}</h1>", version: 3 })
    end
    agent = Mistri::Agent.new(provider:, tools: [tool],
                              session: Mistri::Session.new(store:))
    events = []

    agent.run("edit it") { |event| events << event }

    model_saw = provider.requests.last[:messages].find(&:tool?)

    assert_equal "Updated the hero.", model_saw.text

    event = events.find { |e| e.type == :tool_result }

    assert_equal "Updated the hero.", event.content
    assert_equal({ "html" => "<h1>#{MARKER}</h1>", "version" => 3 }, event.message.ui,
                 "ui arrives canonicalized, identical to what a reload reads")
  end

  def test_ui_persists_for_transcript_re_renders
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    session.append_message(Mistri::Message.tool(content: "saved", tool_call_id: "c1",
                                                tool_name: "edit", ui: { "rows" => [1, 2] }))

    reloaded = Mistri::Session.new(store:, id: session.id).messages.last

    assert_equal({ "rows" => [1, 2] }, reloaded.ui)
    assert_equal "saved", reloaded.text
  end

  def test_ui_never_reaches_any_provider_wire
    call = Mistri::ToolCall.new(id: "c1", name: "edit", arguments: {})
    history = [Mistri::Message.user("go"),
               Mistri::Message.assistant(content: [call], stop_reason: :tool_use),
               Mistri::Message.tool(content: "saved", tool_call_id: "c1", tool_name: "edit",
                                    ui: { "secret" => MARKER })]

    wires = [Mistri::Providers::Anthropic::Serializer.messages(history),
             Mistri::Providers::OpenAI::Serializer.input_items(history),
             Mistri::Providers::Gemini::Serializer.contents(history)]

    wires.each do |wire|
      refute_includes JSON.generate(wire), MARKER, "ui leaked into a provider request"
    end
  end

  def test_plain_returns_still_carry_no_ui
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "plain", arguments: {} }] },
                                             { text: "done" }
                                           ])
    tool = Mistri::Tool.define("plain", "Plain.") { "just text" }
    events = []

    Mistri::Agent.new(provider:, tools: [tool]).run("go") { |e| events << e }

    event = events.find { |e| e.type == :tool_result }

    assert_nil event.message.ui
    assert_equal "just text", event.content
  end

  def test_structured_content_and_ui_travel_together
    tool = Mistri::Tool.define("stats", "Stats.") do
      Mistri::ToolResult.new(content: { "total" => 42 }, ui: { "rows" => [[1], [2]] })
    end

    result = tool.call({})

    assert_equal '{"total":42}', result.content, "data content still serializes as JSON"
    assert_equal({ "rows" => [[1], [2]] }, result.ui)
  end
end
