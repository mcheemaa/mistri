# frozen_string_literal: true

require_relative "test_helper"

# Anthropic's compaction on demand on the wire: the request, the beta header
# on it and on every request that carries the block, the block sent back as
# it came, and the streamed reply with its usage in usage.iterations.
class TestAnthropicCompaction < Minitest::Test
  ASSEMBLER = Mistri::Providers::Anthropic::Assembler
  BLOCK = { "type" => "compaction", "content" => "The ledger is kept.",
            "signature" => "sig" }.freeze
  HISTORY = [Mistri::Message.user("hello")].freeze

  def setup
    @provider = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-5-5")
  end

  def teardown = @provider.close

  def test_a_compaction_request_is_the_turn_s_request_with_the_parameter_and_the_header
    body = @provider.send(:build_body, "claude-opus-5-5", HISTORY, "Be exact.", [],
                          { compaction: { instructions: "Summarize." }, max_tokens: 8_000 })
    plain = @provider.send(:build_body, "claude-opus-5-5", HISTORY, "Be exact.", [], {})

    assert_equal({ type: "summarize", instructions: "Summarize." }, body[:compaction])
    assert_equal body.except(:compaction, :max_tokens), plain.except(:max_tokens)
    betas = @provider.send(:headers, body)["anthropic-beta"].split(",")

    assert_includes betas, "compact-2026-09-04"
    refute_includes @provider.send(:headers, plain)["anthropic-beta"].to_s, "compact"
    refute @provider.send(:headers, { messages: [] }).key?("anthropic-beta")
  end

  def test_a_compaction_with_no_instructions_sends_none
    body = @provider.send(:build_body, "claude-opus-5-5", HISTORY, nil, [], { compaction: {} })

    assert_equal({ type: "summarize" }, body[:compaction])
  end

  def test_the_block_goes_back_first_as_it_came_with_the_header_on_the_request_and_the_count
    block = Mistri::Content::Compaction.new(provider: :anthropic, data: BLOCK, text: "x")
    history = [Mistri::Message.assistant(content: [block], provider: :anthropic),
               Mistri::Message.user("go on")]
    body = @provider.send(:build_body, "claude-opus-5-5", history, nil, [], {})

    assert_equal({ role: "assistant", content: [BLOCK] }, body[:messages].first)
    assert_includes @provider.send(:headers, body)["anthropic-beta"], "compact-2026-09-04"
    assert_includes @provider.send(:headers, body.slice(:model, :messages))["anthropic-beta"],
                    "compact-2026-09-04"
  end

  def test_a_request_with_no_thinking_setting_and_no_block_has_no_beta_header
    plain = Mistri::Providers::Anthropic.new(api_key: "k", thinking: nil)
    body = plain.send(:build_body, "claude-opus-5-5", HISTORY, nil, [], {})

    refute plain.send(:headers, body).key?("anthropic-beta")
  ensure
    plain&.close
  end

  def test_the_api_compacts_for_the_models_of_its_page_on_its_own_origin
    gateway = Mistri::Providers::Anthropic.new(api_key: "k", origin: "https://gateway.example")
    taken = %w[claude-opus-5-5 claude-opus-4-6 claude-sonnet-4-6 claude-haiku-5-5 claude-fable-5-2
               claude-mythos-5 claude-opus-5-5-20261101]
    refused = %w[claude-haiku-4-5 claude-opus-4-5 claude-sonnet-4-5 gpt-6.2-sol custom]

    assert(taken.all? { |id| @provider.compacts?(id) })
    assert(refused.none? { |id| @provider.compacts?(id) })
    refute_predicate gateway, :compacts?
  ensure
    gateway&.close
  end

  def test_the_streamed_reply_is_the_block_with_its_usage_from_the_iterations
    assembler = ASSEMBLER.new(model: "claude-opus-5-5")
    events = []
    records.each { |record| assembler.feed(record) { |event| events << event.type } }
    message = assembler.finish

    assert_equal :stop, message.stop_reason
    assert_equal [Mistri::Content::Compaction.new(provider: :anthropic, data: BLOCK,
                                                  text: "The ledger is kept.")], message.content
    assert_equal [83, 101, 700, 20],
                 message.usage.to_h.values_at(:input, :output, :cache_read, :cache_write)
    assert_predicate message.usage.cost, :known?
    assert_empty events - %i[done]
  end

  def test_a_compaction_that_reports_no_usage_has_no_known_cost
    assembler = ASSEMBLER.new(model: "claude-opus-5-5")
    silent = records.map do |record|
      record["type"] == "message_delta" ? record.except("usage") : record
    end
    empty = records.map do |record|
      next record unless record["type"] == "message_delta"

      record.merge("usage" => record["usage"].merge("iterations" => []))
    end
    silent.each { |record| assembler.feed(record) }
    other = ASSEMBLER.new(model: "claude-opus-5-5")
    empty.each { |record| other.feed(record) }

    refute_predicate assembler.finish.usage.cost, :known?
    refute_predicate other.finish.usage.cost, :known?
  end

  def test_a_reply_with_no_block_keeps_the_stop_reason_of_the_call
    assembler = ASSEMBLER.new(model: "claude-opus-5-5")
    records(block: false, stop: "max_tokens").each { |record| assembler.feed(record) }
    message = assembler.finish

    assert_equal :length, message.stop_reason
    assert_empty message.content
  end

  private

  def records(block: true, stop: "compaction")
    zero = { "input_tokens" => 0, "output_tokens" => 0, "cache_read_input_tokens" => 0,
             "cache_creation_input_tokens" => 0 }
    spent = { "input_tokens" => 83, "output_tokens" => 101, "cache_read_input_tokens" => 700,
              "cache_creation_input_tokens" => 20, "type" => "compaction" }
    content = [{ "type" => "content_block_start", "index" => 0, "content_block" => BLOCK },
               { "type" => "ping" }, { "type" => "content_block_stop", "index" => 0 }]
    [{ "type" => "message_start",
       "message" => { "usage" => zero.merge("service_tier" => "standard") } },
     *(block ? content : []),
     { "type" => "message_delta", "delta" => { "stop_reason" => stop },
       "usage" => zero.merge("iterations" => [spent]) },
     { "type" => "message_stop" }]
  end
end
