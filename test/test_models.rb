# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

class TestModels < Minitest::Test
  def test_known_models_carry_their_output_ceiling
    %w[claude-fable-5-2 claude-fable-5-1 claude-opus-5-5 gpt-6-astra gpt-6.1-sol
       claude-haiku-5-5].each do |id|
      assert_equal 128_000, Mistri::Models.max_output(id)
    end
    assert_equal %i[id provider max_output context_window thinking],
                 Mistri::Models::Model.members
  end

  def test_catalogued_models_carry_their_published_context_windows
    million = %w[claude-fable-5-2
                 claude-fable-5-1 claude-fable-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6
                 claude-sonnet-5 claude-sonnet-4-6 claude-opus-5-5 claude-sonnet-5-5
                 claude-haiku-5-5]

    million.each { |model| assert_equal 1_000_000, Mistri::Models.find(model).context_window }

    assert_equal 200_000, Mistri::Models.find("claude-haiku-4-5").context_window
    %w[gpt-6.2-astra gpt-6.2-sol gpt-6-astra gpt-6.1-sol gpt-6.1-terra gpt-6-luna gpt-6-sol
       gpt-5.6 gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4].each do |model|
      assert_equal 1_050_000, Mistri::Models.find(model).context_window
    end
    assert_equal 400_000, Mistri::Models.find("gpt-5-nano").context_window
    %w[gemini-3.5-flash gemini-3.1-pro-preview gemini-3.8-flash].each do |model|
      assert_equal 1_048_576, Mistri::Models.find(model).context_window
    end
    assert_equal 1_000_000,
                 Mistri::Models.find("claude-opus-4-8-20260701").context_window
  end

  def test_only_shared_context_windows_reserve_output_capacity
    %w[gpt-6-astra gpt-6.1-sol gpt-6.1-terra claude-opus-5-5 claude-fable-5-1].each do |id|
      assert_equal 128_000, Mistri::Models.shared_output(id)
    end
    assert_nil Mistri::Models.shared_output("gemini-3.1-pro-preview")
    assert_nil Mistri::Models.shared_output("future-model")
  end

  def test_pricing_participates_in_model_value_semantics_and_marshalling
    model = Mistri::Models.find("gpt-6.1-sol")
    unpriced = model.with(pricing: [])

    refute_equal model, unpriced
    refute_equal model.hash, unpriced.hash
    assert_equal model, Marshal.load(Marshal.dump(model))
  end

  def test_provider_aliases_and_dated_ids_resolve_while_unknown_ids_pass_through
    sol = Mistri::Models.find("gpt-5.6-sol")

    assert_equal sol, Mistri::Models.find("gpt-5.6")
    assert_equal "gpt-5.6-sol", Mistri::Models.find("gpt-5.6").id
    assert_equal :effort, Mistri::Models.thinking("gpt-5.6")
    assert_equal 128_000, Mistri::Models.max_output("claude-sonnet-5-20260201")
    assert_nil Mistri::Models.find("claude-next-9000")
  end

  def test_dated_ids_preserve_their_capabilities
    { "gpt-6-astra" => %i[openai effort],
      "claude-fable-5-2" => %i[anthropic adaptive],
      "claude-fable-5-1" => %i[anthropic adaptive],
      "claude-opus-5-5" => %i[anthropic adaptive],
      "claude-sonnet-5-5" => %i[anthropic adaptive],
      "claude-haiku-5-5" => %i[anthropic adaptive] }.each do |id, (provider, thinking)|
      model = Mistri::Models.find(id)

      assert_equal provider, model.provider
      assert_equal thinking, Mistri::Models.thinking(id)
      assert_equal model, Mistri::Models.find("#{id}-20260901")
      assert_equal model, Mistri::Models.find("#{id}-2026-09-01")
    end
  end

  def test_astra_and_fable_5_1_enable_native_schemas_and_standard_tier_cost_budgets
    schema = Mistri::Schema.task_plan(Mistri::Schema.build do
      string :answer, required: true
    end).schema
    providers = [
      Mistri::Providers::OpenAI.new(api_key: "test", model: "gpt-6-astra",
                                    service_tier: "default"),
      Mistri::Providers::Anthropic.new(api_key: "test", model: "claude-fable-5-1",
                                       service_tier: "standard_only")
    ]

    providers.each do |provider|
      assert_equal schema, provider.native_output_schema(schema)
      assert_predicate provider, :prices_usage?
    end
  ensure
    providers&.each(&:close)
  end

  def test_gemini_3_8_flash_capabilities_and_scheduled_pricing
    model = Mistri::Models.find("gemini-3.8-flash")

    assert_equal :gemini, model.provider
    assert_equal :level, model.thinking
    assert_equal 65_536, model.max_output
    assert_nil Mistri::Models.shared_output(model.id)
    assert_equal({ input: 0.75, output: 3.75, cache_read: 0.075 },
                 model.rates(at: Time.utc(2026, 12, 31, 23, 59, 59)))
    assert_equal({ input: 1.5, output: 7.5, cache_read: 0.15 },
                 model.rates(at: Time.utc(2027, 1, 1)))
  end

  def test_catalog_pricing_requires_an_official_origin_or_explicit_opt_in
    configurations = [
      [Mistri::Providers::Anthropic, Mistri::Providers::Anthropic::DEFAULT_ORIGIN,
       { service_tier: "standard_only" }],
      [Mistri::Providers::OpenAI, Mistri::Providers::OpenAI::DEFAULT_ORIGIN,
       { service_tier: "default" }],
      [Mistri::Providers::Gemini, Mistri::Providers::Gemini::DEFAULT_ORIGIN, {}]
    ]
    providers = configurations.flat_map do |klass, origin, options|
      [klass.new(api_key: "test", origin: "#{origin}/", **options),
       klass.new(api_key: "test", origin: "https://gateway.example", **options),
       klass.new(api_key: "test", origin: "https://gateway.example",
                 catalog_pricing: true, **options)]
    end

    providers.each_slice(3) do |official, custom, opted_in|
      assert_predicate official, :prices_usage?
      refute_predicate custom, :prices_usage?
      assert_predicate opted_in, :prices_usage?
    end
  ensure
    providers&.each(&:close)
  end

  def test_cost_budget_readiness_requires_a_deterministic_standard_tier
    cases = [
      [Mistri::Providers::Anthropic, nil, false],
      [Mistri::Providers::Anthropic, "auto", false],
      [Mistri::Providers::Anthropic, "priority", false],
      [Mistri::Providers::Anthropic, "standard_only", true],
      [Mistri::Providers::OpenAI, nil, false],
      [Mistri::Providers::OpenAI, "auto", false],
      [Mistri::Providers::OpenAI, "flex", false],
      [Mistri::Providers::OpenAI, "priority", false],
      [Mistri::Providers::OpenAI, "default", true],
      [Mistri::Providers::Gemini, nil, true],
      [Mistri::Providers::Gemini, "", false],
      [Mistri::Providers::Gemini, "unspecified", true],
      [Mistri::Providers::Gemini, "standard", true],
      [Mistri::Providers::Gemini, "flex", false],
      [Mistri::Providers::Gemini, "priority", false]
    ]
    providers = cases.map do |klass, tier, expected|
      provider = klass.new(api_key: "test", service_tier: tier)

      assert_equal expected, provider.prices_usage?, "#{klass.name} #{tier.inspect}"
      provider
    end
  ensure
    providers&.each(&:close)
  end

  def test_the_provider_sends_the_model_ceiling_as_max_tokens
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "type" => "message_stop" })
      server.finish_sse(socket)
    end
    automatic = Mistri::Providers::Anthropic.new(api_key: "test", origin: server.origin,
                                                 catalog_pricing: true)
    standard = Mistri::Providers::Anthropic.new(api_key: "test", origin: server.origin,
                                                catalog_pricing: true,
                                                service_tier: "standard_only")

    seen = []
    automatic.stream(messages: [Mistri::Message.user("hi")]) { |event| seen << event }
    standard.stream(messages: [Mistri::Message.user("hi")])
    body = JSON.parse(server.requests.first[:body])
    standard_body = JSON.parse(server.requests.last[:body])

    assert_equal 128_000, body["max_tokens"]
    assert_equal "claude-opus-5-5", body["model"]
    refute body.key?("service_tier"), "catalog pricing must not choose host policy"
    assert_equal "standard_only", standard_body["service_tier"]
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, body["thinking"])
    assert_equal :start, seen.first.type
    assert_predicate seen.first.partial, :assistant?
    assert_equal :anthropic, seen.first.partial.provider
  ensure
    automatic&.close
    standard&.close
    server&.stop
  end

  def test_service_tiers_are_explicit_provider_policy
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "type" => "response.completed",
                                "response" => { "status" => "completed", "usage" => {} } })
      server.finish_sse(socket)
    end
    automatic = Mistri::Providers::OpenAI.new(api_key: "test", origin: server.origin,
                                              catalog_pricing: true)
    standard = Mistri::Providers::OpenAI.new(api_key: "test", origin: server.origin,
                                             catalog_pricing: true, service_tier: "default")

    seen = []
    automatic.stream(messages: [Mistri::Message.user("hi")]) { |event| seen << event }
    standard.stream(messages: [Mistri::Message.user("hi")])
    automatic_body, standard_body = server.requests.map { |request| JSON.parse(request[:body]) }

    assert_equal "gpt-6.1-sol", automatic_body["model"]
    refute automatic_body.key?("service_tier"), "catalog pricing must not choose host policy"
    assert_equal "default", standard_body["service_tier"]
    assert_equal :start, seen.first.type
    assert_equal :openai, seen.first.partial.provider
  ensure
    automatic&.close
    standard&.close
    server&.stop
  end

  def test_gemini_service_tier_is_explicit_provider_policy
    server = Mistri::Test::StubServer.new do |socket, _request|
      server.start_sse(socket)
      server.sse_data(socket, { "candidates" => [{ "finishReason" => "STOP" }],
                                "usageMetadata" => { "serviceTier" => "standard" } })
      server.finish_sse(socket)
    end
    automatic = Mistri::Providers::Gemini.new(api_key: "test", origin: server.origin,
                                              catalog_pricing: true)
    priority = Mistri::Providers::Gemini.new(api_key: "test", origin: server.origin,
                                             catalog_pricing: true, service_tier: "priority")

    seen = []
    automatic.stream(messages: [Mistri::Message.user("hi")]) { |event| seen << event }
    priority.stream(messages: [Mistri::Message.user("hi")])
    automatic_body, priority_body = server.requests.map { |request| JSON.parse(request[:body]) }

    refute automatic_body.key?("serviceTier"), "catalog pricing must not choose host policy"
    assert_equal "priority", priority_body["serviceTier"]
    assert_equal :start, seen.first.type
    assert_equal :gemini, seen.first.partial.provider
    assert_equal "gemini-3.8-flash", seen.first.partial.model
  ensure
    automatic&.close
    priority&.close
    server&.stop
  end
end
