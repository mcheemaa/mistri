# frozen_string_literal: true

require_relative "test_helper"

class TestGeminiSerializer < Minitest::Test
  SERIALIZER = Mistri::Providers::Gemini::Serializer

  def test_a_freeform_object_schema_passes_through
    tool = Mistri::Tool.define("render", "d", schema: lambda {
      object :config, "Open configuration", required: true
    }) { "ok" }

    wire = SERIALIZER.tools([tool.spec])

    declaration = wire.first[:functionDeclarations].first

    assert_equal tool.input_schema, declaration[:parametersJsonSchema]
    refute declaration.key?(:parameters)
  end

  def test_a_gemini_turn_replays_with_signatures_and_merged_tool_results
    call = Mistri::ToolCall.new(id: "c1", name: "search", arguments: { "q" => "ruby" },
                                signature: "tsig", provider_call_id: "c1")
    assistant = Mistri::Message.assistant(content: "Searching.", tool_calls: [call],
                                          provider: :gemini, stop_reason: :tool_use)
    history = [Mistri::Message.user("go"), assistant,
               Mistri::Message.tool(content: "found", tool_call_id: "c1", tool_name: "search")]

    contents = SERIALIZER.contents(history)

    assert_equal(%w[user model user], contents.map { |turn| turn[:role] })
    call_part = contents[1][:parts].last

    assert_equal "tsig", call_part[:thoughtSignature]
    assert_equal({ name: "search", args: { "q" => "ruby" }, id: "c1" },
                 call_part[:functionCall])
    assert_equal "c1", contents.last[:parts].first[:functionResponse][:id]
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

  def test_foreign_tool_exchanges_project_to_neutral_text
    call = Mistri::ToolCall.new(id: "foreign-1", name: "lookup",
                                arguments: { "q" => "ruby" }, signature: "openai-item")
    assistant = Mistri::Message.assistant(content: [call], provider: :openai,
                                          stop_reason: :tool_use)
    result = Mistri::Message.tool(content: "found", tool_call_id: call.id,
                                  tool_name: call.name)

    contents = SERIALIZER.contents([Mistri::Message.user("go"), assistant, result])

    assert_equal(%w[user model user], contents.map { |turn| turn[:role] })
    refute contents[1][:parts].first.key?(:functionCall)
    refute contents[2][:parts].first.key?(:functionResponse)
    assert_includes contents[1][:parts].first[:text], '"q":"ruby"'
    assert_includes contents[2][:parts].first[:text], "found"
  end

  def test_native_and_foreign_tool_results_never_share_a_wire_turn
    gemini = Mistri::ToolCall.new(id: "gemini-1", name: "one", arguments: {})
    foreign = Mistri::ToolCall.new(id: "foreign-1", name: "two", arguments: {})
    history = [
      Mistri::Message.assistant(content: [gemini], provider: :gemini),
      Mistri::Message.assistant(content: [foreign], provider: :openai),
      Mistri::Message.tool(content: "one", tool_call_id: gemini.id, tool_name: gemini.name),
      Mistri::Message.tool(content: "two", tool_call_id: foreign.id, tool_name: foreign.name)
    ]

    contents = SERIALIZER.contents(history)

    assert contents[-2][:parts].first.key?(:functionResponse)
    assert contents[-1][:parts].first.key?(:text)
  end

  def test_a_tool_result_without_a_tool_name_fails_loudly
    result = Mistri::Message.tool(content: "found", tool_call_id: "c1")

    assert_raises(Mistri::SchemaError) { SERIALIZER.contents([result]) }
  end

  def test_failed_tool_results_use_the_documented_error_key
    call = Mistri::ToolCall.new(id: "c1", name: "search", arguments: {})
    failed = Mistri::Message.tool(content: "unavailable", tool_call_id: "c1",
                                  tool_name: "search", tool_error: true)
    assistant = Mistri::Message.assistant(content: [call], provider: :gemini)

    response = SERIALIZER.contents([assistant, failed]).last[:parts]
                         .first[:functionResponse][:response]

    assert_equal({ "error" => "unavailable" }, response)
  end

  def test_an_unknown_call_origin_projects_consistently_as_text
    call = Mistri::ToolCall.new(id: "legacy", name: "lookup", arguments: {})
    assistant = Mistri::Message.assistant(content: [call], provider: nil)
    result = Mistri::Message.tool(content: "found", tool_call_id: call.id,
                                  tool_name: call.name)

    contents = SERIALIZER.contents([assistant, result])

    assert contents.first[:parts].first.key?(:text)
    assert contents.last[:parts].first.key?(:text)
  end

  def test_invalid_or_non_object_tool_arguments_replay_as_objects
    invalid = Mistri::ToolCall.new(id: "bad", name: "inspect", arguments: nil,
                                   arguments_error: "invalid_json", signature: "invalid-sig")
    scalar = Mistri::ToolCall.new(id: "scalar", name: "inspect", arguments: 7,
                                  signature: "scalar-sig")
    message = Mistri::Message.assistant(content: [invalid, scalar], provider: :gemini)
    parts = SERIALIZER.contents([message]).first[:parts]
    arguments = parts.map { |part| part[:functionCall][:args] }

    assert_equal [{}, {}], arguments
    refute(parts.any? { |part| part.key?(:thoughtSignature) },
           "a changed placeholder cannot retain the provider thought signature")
  end

  def test_a_legacy_call_without_a_wire_id_does_not_mutate_the_signed_part
    call = Mistri::ToolCall.new(id: "internal", name: "inspect", arguments: {},
                                signature: "signed")
    history = [Mistri::Message.assistant(content: [call], provider: :gemini),
               Mistri::Message.tool(content: "ok", tool_call_id: "internal",
                                    tool_name: "inspect")]

    contents = SERIALIZER.contents(history)

    refute contents.first[:parts].first[:functionCall].key?(:id)
    refute contents.last[:parts].first[:functionResponse].key?(:id)
  end

  def test_images_ride_as_inline_data
    image = Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
    contents = SERIALIZER.contents([Mistri::Message.user(["see", image])])

    assert_equal "image/png", contents.first[:parts].last[:inlineData][:mimeType]
  end

  # Mixing a text part into a functionResponse turn makes Gemini answer an
  # empty candidate, and it accepts consecutive user turns, so a steer stays
  # its own turn behind the tool results.
  def test_a_steer_behind_tool_results_stays_a_separate_user_turn
    call = Mistri::ToolCall.new(id: "c1", name: "paint", arguments: {})
    history = [Mistri::Message.user("go"),
               Mistri::Message.assistant(content: [call], provider: :gemini),
               Mistri::Message.tool(content: "painted", tool_call_id: "c1", tool_name: "paint"),
               Mistri::Message.user("make it blue")]

    contents = SERIALIZER.contents(history)

    assert_equal(%w[user model user user], contents.map { |turn| turn[:role] })
    assert(contents[2][:parts].all? { |part| part[:functionResponse] },
           "the tool turn carries only functionResponse parts")
    assert_equal [{ text: "make it blue" }], contents.last[:parts]
  end
end
