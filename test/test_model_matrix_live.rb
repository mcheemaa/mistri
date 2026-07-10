# frozen_string_literal: true

require_relative "test_helper"

# Every catalogued model, exercised against its real API: one streamed turn
# that must land :stop with text and non-zero usage. This is what proves a
# catalog entry is real, its default thinking mode is accepted, and its wire
# path works end to end. Run with MISTRI_LIVE=1.
class TestModelMatrixLive < Minitest::Test
  PROVIDERS = {
    anthropic: { klass: Mistri::Providers::Anthropic, key: "ANTHROPIC_API_KEY",
                 options: { service_tier: "standard_only" } },
    openai: { klass: Mistri::Providers::OpenAI, key: "OPENAI_API_KEY",
              options: { service_tier: "default" } },
    gemini: { klass: Mistri::Providers::Gemini, key: "GEMINI_API_KEY", options: {} }
  }.freeze

  Mistri::Models::CATALOG.each_value do |model|
    define_method("test_#{model.id.gsub(/[.-]/, "_")}_answers_live") do
      config = PROVIDERS.fetch(model.provider)
      next skip "set MISTRI_LIVE=1" unless ENV["MISTRI_LIVE"] == "1"
      next skip "no #{config[:key]}" if ENV[config[:key]].to_s.empty?

      verify_model(model, config)
    end
  end

  private

  def verify_model(model, config)
    provider = config[:klass].new(api_key: ENV.fetch(config[:key]), model: model.id,
                                  **config[:options])
    events = []
    message = provider.stream(
      messages: [Mistri::Message.user("Reply with exactly: ok")]
    ) { |event| events << event }

    assert_equal :stop, message.stop_reason, "#{model.id} did not finish cleanly"
    assert_match(/ok/i, message.text, "#{model.id} produced no usable text")
    assert(events.any? { |e| e.type == :text_delta }, "#{model.id} did not stream")
    assert_operator message.usage.output, :>, 0, "#{model.id} reported no output tokens"
    assert_predicate message.usage.cost, :known?
    assert_operator message.usage.cost.total, :>, 0, "#{model.id} usage was not priced"
  ensure
    provider&.close
  end
end
