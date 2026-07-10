# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

class TestModels < Minitest::Test
  def test_known_models_carry_their_output_ceiling
    assert_equal 128_000, Mistri::Models.max_output("claude-opus-4-8")
    assert_equal 64_000, Mistri::Models.max_output("claude-haiku-4-5")
    assert_equal %i[id provider max_output context_window thinking],
                 Mistri::Models::Model.members
  end

  def test_pricing_participates_in_model_value_semantics_and_marshalling
    model = Mistri::Models.find("gpt-5.5")
    unpriced = model.with(pricing: [])

    refute_equal model, unpriced
    refute_equal model.hash, unpriced.hash
    assert_equal model, Marshal.load(Marshal.dump(model))
  end

  def test_dated_aliases_resolve_and_unknown_ids_pass_through
    assert_equal 128_000, Mistri::Models.max_output("claude-sonnet-5-20260201")
    assert_nil Mistri::Models.find("claude-next-9000")
  end

  def test_catalogued_models_carry_their_published_rates
    rates = Mistri::Models.rates("claude-opus-4-8")

    assert_in_delta 5.0, rates[:input]
    assert_in_delta 25.0, rates[:output]
    assert_in_delta 0.5, rates[:cache_read]
    assert_predicate rates, :frozen?

    assert_nil Mistri::Models.rates("claude-next-9000"), "unknown models carry no rates"
    assert(Mistri::Models::CATALOG.each_value.all?(&:priced?),
           "every catalogued model carries verified rates")
  end

  def test_openai_long_context_pricing_uses_each_requests_prompt_size
    boundary = Mistri::Usage.new(input: 200_000, cache_read: 72_000)
    over = boundary.with(cache_read: 72_001)

    { "gpt-5.5" => [5.0, 10.0, 1.0, 45.0],
      "gpt-5.4" => [2.5, 5.0, 0.5, 22.5] }.each do |model, values|
      base, higher, cache_read, output = values

      assert_in_delta base, Mistri::Models.rates(model, usage: boundary)[:input]
      rates = Mistri::Models.rates(model, usage: over)

      assert_in_delta higher, rates[:input]
      assert_in_delta cache_read, rates[:cache_read]
      assert_in_delta output, rates[:output]
    end
  end

  def test_gemini_pro_long_context_pricing_starts_above_200k
    boundary = Mistri::Usage.new(input: 100_000, cache_read: 100_000)
    over = boundary.with(cache_read: 100_001)

    { "gemini-3.1-pro-preview" => [2.0, 4.0, 0.4, 18.0],
      "gemini-2.5-pro" => [1.25, 2.5, 0.25, 15.0] }.each do |model, values|
      base, higher, cache_read, output = values

      assert_in_delta base, Mistri::Models.rates(model, usage: boundary)[:input]
      rates = Mistri::Models.rates(model, usage: over)

      assert_in_delta higher, rates[:input]
      assert_in_delta cache_read, rates[:cache_read]
      assert_in_delta output, rates[:output]
    end
  end

  def test_flat_pricing_does_not_change_for_large_prompts
    usage = Mistri::Usage.new(input: 900_000)

    assert_equal Mistri::Models.rates("gpt-5-nano"),
                 Mistri::Models.rates("gpt-5-nano", usage:)
    assert_equal Mistri::Models.rates("gemini-3.5-flash"),
                 Mistri::Models.rates("gemini-3.5-flash", usage:)
  end

  def test_sonnet_5_pricing_changes_at_the_published_instant
    before = Mistri::Models.rates("claude-sonnet-5", at: Time.utc(2026, 8, 31, 23, 59, 59))
    after = Mistri::Models.rates("claude-sonnet-5", at: Time.utc(2026, 9, 1))

    assert_in_delta 2.0, before[:input]
    assert_in_delta 10.0, before[:output]
    assert_in_delta 3.0, after[:input]
    assert_in_delta 15.0, after[:output]
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
    assert_equal "claude-opus-4-8", body["model"]
    refute body.key?("service_tier"), "catalog pricing must not choose host policy"
    assert_equal "standard_only", standard_body["service_tier"]
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, body["thinking"])
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

    automatic.stream(messages: [Mistri::Message.user("hi")])
    standard.stream(messages: [Mistri::Message.user("hi")])
    automatic_body, standard_body = server.requests.map { |request| JSON.parse(request[:body]) }

    refute automatic_body.key?("service_tier"), "catalog pricing must not choose host policy"
    assert_equal "default", standard_body["service_tier"]
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

    automatic.stream(messages: [Mistri::Message.user("hi")])
    priority.stream(messages: [Mistri::Message.user("hi")])
    automatic_body, priority_body = server.requests.map { |request| JSON.parse(request[:body]) }

    refute automatic_body.key?("serviceTier"), "catalog pricing must not choose host policy"
    assert_equal "priority", priority_body["serviceTier"]
  ensure
    automatic&.close
    priority&.close
    server&.stop
  end
end
