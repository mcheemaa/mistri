# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestUsage < Minitest::Test
  def test_zero_is_the_identity_for_addition
    usage = Mistri::Usage.new(input: 100, output: 20, reasoning: 8)

    assert_equal usage, Mistri::Usage.zero + usage
  end

  def test_turns_accumulate_across_a_run
    total = Mistri::Usage.new(input: 100, output: 20, cache_read: 400) +
            Mistri::Usage.new(input: 50, output: 10, cache_read: 500, cache_write: 30)

    assert_equal 150, total.input
    assert_equal 900, total.cache_read
    assert_equal 1110, total.total_tokens
  end

  def test_prompt_tokens_include_every_input_price_class
    usage = Mistri::Usage.new(input: 100, cache_read: 200, cache_write: 300, output: 400)

    assert_equal 600, usage.prompt_tokens
  end

  def test_unpriced_usage_is_unknown_but_zero_usage_is_known
    refute_predicate Mistri::Usage.new(input: 1).cost, :known?
    assert_predicate Mistri::Usage.zero.cost, :known?
    refute_equal Mistri::Usage::Cost.unknown, Mistri::Usage::Cost.zero
    assert_equal %i[input output cache_read cache_write total], Mistri::Usage::Cost.members
  end

  def test_aggregate_cost_is_known_only_when_every_turn_is_priced
    priced = Mistri::Usage.new(input: 10).with_cost(input: 1.0)
    mixed = priced + Mistri::Usage.new(input: 5)

    assert_predicate priced.cost, :known?
    refute_predicate mixed.cost, :known?
    assert_operator mixed.cost.total, :>, 0
  end

  def test_cost_bills_the_1h_cache_write_slice_at_twice_the_input_rate
    usage = Mistri::Usage.new(input: 1_000_000, cache_write: 100, cache_write_1h: 40)
    priced = usage.with_cost(input: 3.0, output: 15.0, cache_write: 3.75)

    assert_in_delta 3.0, priced.cost.input
    # 60 short tokens at 3.75 plus 40 long tokens at 2 x 3.0, per million.
    assert_in_delta ((3.75 * 60) + (6.0 * 40)) / 1_000_000, priced.cost.cache_write
    assert_in_delta priced.cost.input + priced.cost.cache_write, priced.cost.total
  end

  def test_a_missing_rate_keeps_cost_unknown
    usage = Mistri::Usage.new(input: 10, output: 5).with_cost(input: 1.0)

    refute_predicate usage.cost, :known?
  end

  def test_nonzero_costs_survive_a_json_round_trip
    usage = Mistri::Usage.new(input: 10, output: 5, cache_write: 100, cache_write_1h: 40)
                         .with_cost(input: 3.0, output: 15.0, cache_write: 3.75)

    assert_equal usage, Mistri::Usage.from_h(JSON.parse(JSON.generate(usage.to_h)))
  end

  def test_unknown_cost_survives_a_json_round_trip
    usage = Mistri::Usage.new(input: 10)

    assert_equal usage, Mistri::Usage.from_h(JSON.parse(JSON.generate(usage.to_h)))
  end

  def test_known_state_survives_a_marshal_round_trip
    [Mistri::Usage::Cost.zero, Mistri::Usage::Cost.unknown].each do |cost|
      assert_equal cost, Marshal.load(Marshal.dump(cost))
    end
  end

  def test_legacy_cost_without_a_known_marker_is_conservative
    usage = Mistri::Usage.from_h("input" => 10,
                                 "cost" => { "input" => 0.1, "total" => 0.1 })

    refute_predicate usage.cost, :known?
  end

  def test_legacy_serialized_zero_usage_remains_known_zero
    legacy = { "input" => 0, "output" => 0, "cache_read" => 0, "cache_write" => 0,
               "cache_write_1h" => 0, "reasoning" => 0,
               "cost" => { "input" => 0.0, "output" => 0.0, "cache_read" => 0.0,
                           "cache_write" => 0.0, "total" => 0.0 } }

    assert_equal Mistri::Usage.zero, Mistri::Usage.from_h(legacy)
  end

  def test_only_a_literal_true_known_marker_is_trusted
    usage = Mistri::Usage.from_h("input" => 10,
                                 "cost" => { "input" => 0.1, "total" => 0.1,
                                             "known" => "false" })

    refute_predicate usage.cost, :known?
  end
end
