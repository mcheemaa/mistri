# frozen_string_literal: true

require_relative "test_helper"

class TestGeminiSerializer < Minitest::Test
  SERIALIZER = Mistri::Providers::Gemini::Serializer

  def test_a_gemini_turn_replays_with_signatures_and_merged_tool_results
    call = Mistri::ToolCall.new(id: "c1", name: "search", arguments: { "q" => "ruby" },
                                signature: "tsig")
    assistant = Mistri::Message.assistant(content: "Searching.", tool_calls: [call],
                                          provider: :gemini, stop_reason: :tool_use)
    history = [Mistri::Message.user("go"), assistant,
               Mistri::Message.tool(content: "found", tool_call_id: "c1", tool_name: "search")]

    contents = SERIALIZER.contents(history)

    assert_equal(%w[user model user], contents.map { |turn| turn[:role] })
    call_part = contents[1][:parts].last

    assert_equal "tsig", call_part[:thoughtSignature]
    assert_equal({ name: "search", args: { "q" => "ruby" } }, call_part[:functionCall])
    assert_equal({ "result" => "found" },
                 contents.last[:parts].first[:functionResponse][:response])
  end

  def test_foreign_signatures_never_leak_and_thinking_never_replays
    foreign = Mistri::Message.assistant(
      content: [Mistri::Content::Thinking.new(thinking: "hmm", signature: "anthropic-sig"),
                Mistri::Content::Text.new(text: "hi", signature: "msg_1")],
      provider: :anthropic
    )

    contents = SERIALIZER.contents([foreign])
    parts = contents.first[:parts]

    assert_equal [{ text: "hi" }], parts
  end

  def test_images_ride_as_inline_data
    image = Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
    contents = SERIALIZER.contents([Mistri::Message.user(["see", image])])

    assert_equal "image/png", contents.first[:parts].last[:inlineData][:mimeType]
  end
end
