# frozen_string_literal: true

require_relative "mistri/version"
require_relative "mistri/errors"
require_relative "mistri/stop_reason"
require_relative "mistri/usage"
require_relative "mistri/models"
require_relative "mistri/tool_call"
require_relative "mistri/content"
require_relative "mistri/message"
require_relative "mistri/event"
require_relative "mistri/abort_signal"
require_relative "mistri/sse"
require_relative "mistri/partial_json"
require_relative "mistri/transport"
require_relative "mistri/schema"
require_relative "mistri/edit"
require_relative "mistri/tool"
require_relative "mistri/workspace/memory"
require_relative "mistri/workspace/directory"
require_relative "mistri/workspace/single"
require_relative "mistri/memory"
require_relative "mistri/tools"
require_relative "mistri/tool_executor"
require_relative "mistri/budget"
require_relative "mistri/stores/memory"
require_relative "mistri/stores/jsonl"
require_relative "mistri/session"
require_relative "mistri/result"
require_relative "mistri/agent"
require_relative "mistri/providers/fake"
require_relative "mistri/providers/anthropic"
require_relative "mistri/providers/openai"
require_relative "mistri/providers/gemini"

# Mistri (مستری): the fixer. An agent harness for Ruby applications.
module Mistri
  PROVIDERS = { anthropic: Providers::Anthropic, openai: Providers::OpenAI,
                gemini: Providers::Gemini }.freeze
  API_KEY_ENV = { anthropic: "ANTHROPIC_API_KEY", openai: "OPENAI_API_KEY",
                  gemini: "GEMINI_API_KEY" }.freeze

  module_function

  # Build a provider for a model, inferring which one from the model id and
  # reading its key from the environment unless one is passed.
  #
  #   Mistri.provider("claude-opus-4-8")
  #   Mistri.provider("gpt-5.5", api_key: key, reasoning: { effort: "high" })
  def provider(model, api_key: nil, **)
    name = provider_name(model)
    klass = PROVIDERS.fetch(name) { raise ConfigurationError, "no provider for #{model.inspect}" }
    key = api_key || ENV.fetch(API_KEY_ENV.fetch(name), nil)
    raise ConfigurationError, "no API key for #{name}" if key.to_s.empty?

    klass.new(api_key: key, model: model, **)
  end

  # Build an agent for a model in one call: infers and constructs the provider,
  # then wraps it in the loop.
  #
  #   agent = Mistri.agent("claude-opus-4-8", tools: [weather], system: "Be brief.")
  #   agent.run("Weather in Lahore?") { |event| ... }
  def agent(model, api_key: nil, provider_options: {}, **agent_options)
    built = provider(model, api_key: api_key, **provider_options)
    Agent.new(provider: built, **agent_options)
  end

  # Catalogued models infer directly; unknown ids fall back to the id prefix,
  # so a brand-new model works before it is catalogued.
  def provider_name(model)
    Models.find(model)&.provider || infer_provider_name(model)
  end

  def infer_provider_name(model)
    case model.to_s
    when /\Aclaude/ then :anthropic
    when /\A(gpt|o\d|chatgpt)/ then :openai
    when /\Agemini/ then :gemini
    else raise ConfigurationError, "cannot infer a provider from #{model.inspect}"
    end
  end
end
