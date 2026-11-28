# frozen_string_literal: true

require_relative "test_helper"

# OpenAI's compaction on a trigger on the wire: the trigger as the last input
# item, the sealed item kept as it came and sent back first, and the gem's own
# summary placed after the turns it leaves, where their reasoning stays.
class TestOpenAICompaction < Minitest::Test
  ASSEMBLER = Mistri::Providers::OpenAI::Assembler
  ITEM = { "id" => "cmp_1", "type" => "compaction", "encrypted_content" => "gAAAAAB" }.freeze
  HISTORY = [Mistri::Message.user("hello")].freeze

  def setup
    @provider = Mistri::Providers::OpenAI.new(api_key: "k", model: "gpt-6.2-sol")
  end

  def teardown = @provider.close

  def test_a_compaction_request_ends_with_the_trigger_and_sends_no_output_limit
    body = @provider.send(:build_body, "gpt-6.2-sol", HISTORY, "Be exact.", [],
                          { compaction: { instructions: "ignored" }, max_tokens: 16_384 })
    plain = @provider.send(:build_body, "gpt-6.2-sol", HISTORY, "Be exact.", [],
                           { max_tokens: 16_384 })

    assert_equal({ type: "compaction_trigger" }, body[:input].last)
    assert_equal plain[:input], body[:input][0...-1]
    refute body.key?(:max_output_tokens)
    assert_equal 16_384, plain[:max_output_tokens]
  end

  def test_the_item_goes_back_as_it_came_after_the_system_prompt
    block = Mistri::Content::Compaction.new(provider: :openai, data: ITEM)
    history = [Mistri::Message.assistant(content: [block], provider: :openai),
               Mistri::Message.user("go on")]
    input = @provider.send(:build_body, "gpt-6.2-sol", history, "Be exact.", [], {})[:input]

    assert_equal "developer", input.first[:role]
    assert_equal ITEM, input[1]
    assert_equal "user", input.last[:role]
  end

  def test_the_api_compacts_for_every_gpt_5_model_and_later_on_its_own_origin
    gateway = Mistri::Providers::OpenAI.new(api_key: "k", origin: "https://gateway.example")
    taken = %w[gpt-5-nano gpt-5.4 gpt-5.6-sol gpt-6.2-sol gpt-7 gpt-6.2-sol-2026-11-01]
    refused = %w[gpt-4.1 gpt-4o o4-mini custom]

    assert(taken.all? { |id| @provider.compacts?(id) })
    assert(refused.none? { |id| @provider.compacts?(id) })
    refute_predicate gateway, :compacts?
    assert_predicate @provider, :summary_after_kept?
  ensure
    gateway&.close
  end

  def test_the_streamed_reply_is_the_sealed_item
    assembler = ASSEMBLER.new(model: "gpt-6.2-sol")
    records = [
      { "type" => "response.output_item.done" },
      { "type" => "response.output_item.added", "output_index" => 0, "item" => ITEM },
      { "type" => "response.compaction.compacting" },
      { "type" => "response.output_item.done", "output_index" => 0, "item" => ITEM },
      { "type" => "response.completed",
        "response" => { "status" => "completed",
                        "usage" => { "input_tokens" => 103, "output_tokens" => 82 } } }
    ]
    records.each { |record| assembler.feed(record) }
    message = assembler.finish

    assert_equal :stop, message.stop_reason
    assert_equal [Mistri::Content::Compaction.new(provider: :openai, data: ITEM)], message.content
    assert_equal [103, 82], [message.usage.input, message.usage.output]
  end
end
