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

  def test_a_tool_result_without_a_tool_name_fails_loudly
    result = Mistri::Message.tool(content: "found", tool_call_id: "c1")

    assert_raises(Mistri::SchemaError) { SERIALIZER.contents([result]) }
  end

  def test_images_ride_as_inline_data
    image = Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
    contents = SERIALIZER.contents([Mistri::Message.user(["see", image])])

    assert_equal "image/png", contents.first[:parts].last[:inlineData][:mimeType]
  end

  def test_a_steer_behind_tool_results_merges_into_one_user_turn
    call = Mistri::ToolCall.new(id: "c1", name: "paint", arguments: {})
    history = [Mistri::Message.user("go"),
               Mistri::Message.assistant(content: [call], provider: :gemini),
               Mistri::Message.tool(content: "painted", tool_call_id: "c1", tool_name: "paint"),
               Mistri::Message.user("make it blue")]

    contents = SERIALIZER.contents(history)

    assert_equal(%w[user model user], contents.map { |turn| turn[:role] })
    merged = contents.last[:parts]

    assert(merged.any? { |part| part[:functionResponse] })
    assert_equal "make it blue", merged.last[:text]
  end
end
