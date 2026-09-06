# frozen_string_literal: true

require_relative "test_helper"

# The summary is the compactor's own request: its output limit and thinking come
# from compaction settings and the API, never from the host's chat configuration.
class TestCompactionRequest < Minitest::Test
  HISTORY = [Mistri::Message.user("hello")].freeze

  def test_the_summary_request_uses_its_own_output_limit_and_default_thinking
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])

    Mistri::Compactor.call(session: history, provider:, settings: settings)

    options = provider.requests.first[:options]

    assert_equal Mistri::Compaction::DEFAULT_MAX_TOKENS, options[:max_tokens]
    assert_equal [nil, nil], options.values_at(:thinking, :reasoning)
    assert options.key?(:thinking)
    assert options.key?(:reasoning)
    assert_equal Mistri::Compactor::SUMMARIZER_SYSTEM, options[:system]
  end

  def test_the_summary_output_limit_is_host_policy_capped_at_the_model_ceiling
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }, { text: "Summary." }])
    provider.define_singleton_method(:model) { "claude-haiku-4-5" }
    ceiling = Mistri::Models.max_output("claude-haiku-4-5")

    Mistri::Compactor.call(session: history, provider:, settings: settings(max_tokens: 2_000))
    Mistri::Compactor.call(session: history, provider:, settings: settings(max_tokens: ceiling * 2))

    limits = provider.requests.map { |request| request[:options][:max_tokens] }

    assert_equal [2_000, ceiling], limits
  end

  def test_every_built_in_provider_sends_the_summary_limit_in_its_own_field
    overrides = { max_tokens: 400, thinking: nil, reasoning: nil }
    openai = Mistri::Providers::OpenAI.new(api_key: "k", reasoning: { effort: "high" })
    gemini = Mistri::Providers::Gemini.new(api_key: "k")
    anthropic = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-4-8",
                                                 max_tokens: 1_024)

    openai_body = openai.send(:build_body, "gpt-5.6", HISTORY, nil, [], overrides)
    gemini_body = gemini.send(:build_body, HISTORY, nil, [], overrides)
    anthropic_body = anthropic.send(:build_body, "claude-opus-4-8", HISTORY, nil, [], overrides)

    assert_equal 400, openai_body[:max_output_tokens]
    refute openai_body.key?(:reasoning), "the host's reasoning effort must not reach the summary"
    assert_equal 400, gemini_body.dig(:generationConfig, :maxOutputTokens)
    refute gemini_body.dig(:generationConfig, :thinkingConfig)
    assert_equal 400, anthropic_body[:max_tokens]
    refute anthropic_body.key?(:thinking)
  ensure
    [openai, gemini, anthropic].compact.each(&:close)
  end

  def test_ordinary_requests_keep_the_hosts_settings_and_no_cap
    openai = Mistri::Providers::OpenAI.new(api_key: "k", reasoning: { effort: "high" })
    gemini = Mistri::Providers::Gemini.new(api_key: "k")
    anthropic = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-4-8",
                                                 max_tokens: 1_024)

    openai_body = openai.send(:build_body, "gpt-5.6", HISTORY, nil, [], {})
    gemini_body = gemini.send(:build_body, HISTORY, nil, [], {})
    anthropic_body = anthropic.send(:build_body, "claude-opus-4-8", HISTORY, nil, [], {})

    refute openai_body.key?(:max_output_tokens)
    assert_equal({ effort: "high" }, openai_body[:reasoning])
    refute gemini_body.dig(:generationConfig, :maxOutputTokens)
    assert_equal({ includeThoughts: true }, gemini_body.dig(:generationConfig, :thinkingConfig))
    assert_equal 1_024, anthropic_body[:max_tokens]
    assert_equal({ type: "adaptive", display: "summarized" }, anthropic_body[:thinking])
  ensure
    [openai, gemini, anthropic].compact.each(&:close)
  end

  def test_the_summary_limit_must_be_a_positive_integer
    [nil, 0, -1, 1.5, "400", false].each do |value|
      error = assert_raises(ArgumentError) { Mistri::Compaction.new(max_tokens: value) }

      assert_equal "max_tokens must be a positive Integer", error.message
    end
    assert_equal 400, Mistri::Compaction.new(max_tokens: 400).max_tokens
  end

  private

  def settings(**overrides)
    Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 10, **overrides)
  end

  def history
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.append_message(Mistri::Message.user("Original export rules. " * 80))
    session.append_message(Mistri::Message.assistant(content: "Source inspected. " * 80,
                                                     stop_reason: :stop))
    session.append_message(Mistri::Message.user("Retain this follow-up. " * 80))
    session
  end
end
