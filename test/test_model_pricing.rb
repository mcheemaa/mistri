# frozen_string_literal: true

require_relative "test_helper"

# The catalog's prices: the standard rates of each model, the step at a prompt
# size, the cache rates, and a price that changes on a date.
class TestModelPricing < Minitest::Test
  def test_catalogued_models_carry_their_published_rates
    rates = Mistri::Models.rates("claude-opus-5-5")

    assert_equal({ input: 4.0, output: 20.0, cache_read: 0.2, cache_write: 5.0 }, rates)
    assert_predicate rates, :frozen?
    assert_equal({ input: 8.0, output: 40.0, cache_read: 0.2, cache_write: 10.0 },
                 Mistri::Models.rates("claude-fable-5-2"))

    assert_nil Mistri::Models.rates("claude-next-9000"), "unknown models carry no rates"
    assert(Mistri::Models::CATALOG.each_value.all?(&:priced?),
           "every catalogued model carries verified rates")
  end

  def test_astra_pricing_includes_cache_writes_on_both_context_tiers
    boundary = Mistri::Usage.new(input: 100_000, cache_read: 100_000, cache_write: 72_000)
    over = boundary.with(cache_write: 72_001)
    standard = { input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5 }
    higher = { input: 20.0, output: 75.0, cache_read: 2.0, cache_write: 25.0 }

    assert_equal standard, Mistri::Models.rates("gpt-6-astra")
    assert_equal standard, Mistri::Models.rates("gpt-6-astra", usage: boundary)
    assert_equal higher, Mistri::Models.rates("gpt-6-astra", usage: over)
  end

  def test_fable_5_1_pricing_covers_both_cache_retention_windows
    rates = Mistri::Models.rates("claude-fable-5-1")
    usage = Mistri::Usage.new(input: 300_000, output: 100_000, cache_read: 200_000,
                              cache_write: 300_000, cache_write_1h: 100_000)
    priced = usage.with_cost(rates)

    assert_equal({ input: 10.0, output: 50.0, cache_read: 0.25, cache_write: 12.5 }, rates)
    assert_equal rates, Mistri::Models.rates("claude-fable-5-1", usage:)
    assert_in_delta 0.05, priced.cost.cache_read
    assert_in_delta 4.5, priced.cost.cache_write
    assert_in_delta 12.55, priced.cost.total
    assert_predicate priced.cost, :known?
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

  def test_openai_pricing_includes_cache_writes_on_both_context_tiers
    boundary = Mistri::Usage.new(input: 100_000, cache_read: 100_000, cache_write: 72_000)
    over = boundary.with(cache_write: 72_001)
    prices = {
      "gpt-6.2-astra" => [
        { input: 8.0, output: 40.0, cache_read: 0.4, cache_write: 10.0 },
        { input: 16.0, output: 60.0, cache_read: 0.8, cache_write: 20.0 }
      ],
      "gpt-6.2-sol" => [
        { input: 2.0, output: 10.0, cache_read: 0.1, cache_write: 2.5 },
        { input: 4.0, output: 15.0, cache_read: 0.2, cache_write: 5.0 }
      ],
      "gpt-6-sol" => [
        { input: 2.0, output: 10.0, cache_read: 0.2, cache_write: 2.5 },
        { input: 4.0, output: 15.0, cache_read: 0.4, cache_write: 5.0 }
      ],
      "gpt-6.1-sol" => [
        { input: 2.0, output: 10.0, cache_read: 0.1, cache_write: 2.5 },
        { input: 4.0, output: 15.0, cache_read: 0.2, cache_write: 5.0 }
      ],
      "gpt-6.1-terra" => [
        { input: 1.0, output: 5.0, cache_read: 0.05, cache_write: 1.25 },
        { input: 2.0, output: 7.5, cache_read: 0.1, cache_write: 2.5 }
      ],
      "gpt-6-luna" => [
        { input: 0.1, output: 0.5, cache_read: 0.01, cache_write: 0.125 },
        { input: 0.2, output: 0.75, cache_read: 0.02, cache_write: 0.25 }
      ],
      "gpt-5.6-terra" => [
        { input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 2.5 },
        { input: 4.0, output: 18.0, cache_read: 0.4, cache_write: 5.0 }
      ],
      "gpt-5.6-luna" => [
        { input: 0.2, output: 1.2, cache_read: 0.02, cache_write: 0.25 },
        { input: 0.4, output: 1.8, cache_read: 0.04, cache_write: 0.5 }
      ]
    }

    prices.each do |model, (standard, higher)|
      assert_equal standard, Mistri::Models.rates(model, usage: boundary)
      assert_equal higher, Mistri::Models.rates(model, usage: over)
    end
    assert_equal Mistri::Models.rates("gpt-5.6-sol"), Mistri::Models.rates("gpt-5.6")
  end

  def test_gpt_5_6_sol_returns_to_its_list_price_when_the_promotion_ends
    over = Mistri::Usage.new(input: 272_001)
    last_day = Time.utc(2026, 12, 1, 7, 59, 59)
    first_day = Time.utc(2026, 12, 1, 8)

    assert_equal({ input: 4.0, output: 20.0, cache_read: 0.4, cache_write: 5.0 },
                 Mistri::Models.rates("gpt-5.6-sol", at: last_day))
    assert_equal({ input: 8.0, output: 30.0, cache_read: 0.8, cache_write: 10.0 },
                 Mistri::Models.rates("gpt-5.6-sol", usage: over, at: last_day))
    assert_equal({ input: 5.0, output: 30.0, cache_read: 0.5, cache_write: 6.25 },
                 Mistri::Models.rates("gpt-5.6", at: first_day))
    assert_equal({ input: 10.0, output: 45.0, cache_read: 1.0, cache_write: 12.5 },
                 Mistri::Models.rates("gpt-5.6-sol", usage: over, at: first_day))
  end

  def test_haiku_pricing_changes_only_above_100k_prompt_tokens
    boundary = Mistri::Usage.new(input: 80_000, cache_read: 20_000)
    over = boundary.with(input: 80_001)

    assert_equal({ input: 0.1, output: 0.5, cache_read: 0.01, cache_write: 0.125 },
                 Mistri::Models.rates("claude-haiku-5-5", usage: boundary))
    assert_equal({ input: 0.5, output: 2.5, cache_read: 0.05, cache_write: 0.625 },
                 Mistri::Models.rates("claude-haiku-5-5", usage: over))
  end

  def test_gemini_pro_long_context_pricing_starts_above_200k
    boundary = Mistri::Usage.new(input: 100_000, cache_read: 100_000)
    over = boundary.with(cache_read: 100_001)

    assert_in_delta 2.0, Mistri::Models.rates("gemini-3.1-pro-preview", usage: boundary)[:input]
    rates = Mistri::Models.rates("gemini-3.1-pro-preview", usage: over)

    assert_in_delta 4.0, rates[:input]
    assert_in_delta 0.4, rates[:cache_read]
    assert_in_delta 18.0, rates[:output]
  end

  def test_gemini_4_prices_and_the_end_of_the_introductory_price
    intro = { input: 2.0, output: 10.0, cache_read: 0.1 }
    list = { input: 4.0, output: 20.0, cache_read: 0.2 }
    large = Mistri::Usage.new(input: 900_000)

    %w[gemini-4-carbon gemini-4-argon].each do |id|
      assert_equal intro, Mistri::Models.rates(id, at: Time.utc(2026, 11, 30, 23, 59, 59))
      assert_equal list, Mistri::Models.rates(id, at: Time.utc(2026, 12, 1))
      assert_equal list, Mistri::Models.rates(id, usage: large, at: Time.utc(2026, 12, 1))
    end
    assert_equal({ input: 3.0, output: 15.0, cache_read: 0.15 },
                 Mistri::Models.rates("gemini-4-neon", usage: large))
    assert_equal({ input: 1.5, output: 7.5, cache_read: 0.075 },
                 Mistri::Models.rates("gemini-4-hydrogen", usage: large))
  end

  def test_the_earlier_gemini_flash_models_carry_their_published_rates
    assert_equal({ input: 0.75, output: 3.75, cache_read: 0.075 },
                 Mistri::Models.rates("gemini-3.6-flash", at: Time.utc(2026, 12, 31)))
    assert_equal({ input: 1.5, output: 7.5, cache_read: 0.15 },
                 Mistri::Models.rates("gemini-3.5-flash", at: Time.utc(2027, 1, 1)))
    assert_equal({ input: 0.3, output: 2.5, cache_read: 0.03 },
                 Mistri::Models.rates("gemini-3.5-flash-lite"))
  end

  def test_flat_pricing_does_not_change_for_large_prompts
    usage = Mistri::Usage.new(input: 900_000)

    assert_equal Mistri::Models.rates("gpt-5-nano"),
                 Mistri::Models.rates("gpt-5-nano", usage:)
    assert_equal Mistri::Models.rates("gemini-3.5-flash"),
                 Mistri::Models.rates("gemini-3.5-flash", usage:)
  end
end
