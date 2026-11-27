# frozen_string_literal: true

require_relative "test_helper"

# GPT-6.2 and later append top-level instructions after the input, where no
# cache breakpoint reaches them, so the system prompt leads the input as a
# developer message. Another origin may refuse the role and keeps instructions.
class TestOpenAISystemPrompt < Minitest::Test
  HISTORY = [Mistri::Message.user("hello")].freeze

  def teardown = @provider&.close

  def body(origin: Mistri::Providers::OpenAI::DEFAULT_ORIGIN, system: "Follow the rules.")
    @provider&.close
    @provider = Mistri::Providers::OpenAI.new(api_key: "k", origin:)
    @provider.send(:build_body, "gpt-6.2-sol", HISTORY, system, [], {})
  end

  def test_the_system_prompt_leads_the_input_as_a_developer_message
    sent = body

    assert_equal({ role: "developer",
                   content: [{ type: "input_text", text: "Follow the rules." }] },
                 sent[:input].first)
    assert_equal(%w[developer user], sent[:input].map { |item| item[:role] })
    refute sent.key?(:instructions)
  end

  def test_another_origin_receives_the_system_prompt_as_instructions
    sent = body(origin: "https://gateway.example")

    assert_equal "Follow the rules.", sent[:instructions]
    assert_equal(%w[user], sent[:input].map { |item| item[:role] })
  end

  def test_no_system_prompt_adds_nothing
    [nil, ""].each do |system|
      sent = body(system:)

      assert_equal(%w[user], sent[:input].map { |item| item[:role] })
      refute sent.key?(:instructions)
    end
  end
end
