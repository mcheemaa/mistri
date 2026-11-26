# frozen_string_literal: true

require_relative "test_helper"

# What the result of an MCP call becomes for a model, for the content a
# bridge cannot show and for an error that says the same thing twice.
class TestMcpResults < Minitest::Test
  def test_content_of_a_type_the_bridge_does_not_know_is_named
    result = { "content" => [{ "type" => "text", "text" => "A recording:" },
                             { "type" => "audio", "data" => "AAAA", "mimeType" => "audio/wav" }] }

    assert_equal "A recording:\n[unsupported audio content]", Mistri::MCP.answer(result)
  end

  def test_an_error_whose_text_is_its_structured_content_holds_it_once
    failed = { "isError" => true, "structuredContent" => { "code" => "RATE_LIMITED" },
               "content" => [{ "type" => "text", "text" => '{"code":"RATE_LIMITED"}' }] }

    answer = Mistri::MCP.answer(failed)

    assert_predicate answer, :error?
    assert_equal 'MCP tool error: {"code":"RATE_LIMITED"}', answer.content
  end
end
