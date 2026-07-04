# frozen_string_literal: true

require_relative "test_helper"

class TestEntrypoint < Minitest::Test
  def test_provider_is_inferred_from_the_model_id
    assert_instance_of Mistri::Providers::Anthropic,
                       Mistri.provider("claude-opus-4-8", api_key: "k")
    assert_instance_of Mistri::Providers::OpenAI, Mistri.provider("gpt-5.5", api_key: "k")
    assert_instance_of Mistri::Providers::Gemini, Mistri.provider("gemini-2.5-flash", api_key: "k")
  end

  def test_an_uncatalogued_id_infers_from_its_prefix
    assert_instance_of Mistri::Providers::Anthropic, Mistri.provider("claude-next-9", api_key: "k")
    assert_instance_of Mistri::Providers::OpenAI, Mistri.provider("o5-preview", api_key: "k")
  end

  def test_an_unrecognizable_model_raises_configuration_error
    assert_raises(Mistri::ConfigurationError) { Mistri.provider("llama-3", api_key: "k") }
  end

  def test_a_missing_key_raises_configuration_error
    original = ENV.delete("ANTHROPIC_API_KEY")
    assert_raises(Mistri::ConfigurationError) { Mistri.provider("claude-opus-4-8") }
  ensure
    ENV["ANTHROPIC_API_KEY"] = original
  end

  def test_agent_builds_a_loop_over_the_inferred_provider
    agent = Mistri.agent("claude-opus-4-8", api_key: "k", system: "Be brief.")

    assert_instance_of Mistri::Agent, agent
  end
end
