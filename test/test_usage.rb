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

  def test_cost_bills_the_1h_cache_write_slice_at_twice_the_input_rate
    usage = Mistri::Usage.new(input: 1_000_000, cache_write: 100, cache_write_1h: 40)
    priced = usage.with_cost(input: 3.0, output: 15.0, cache_write: 3.75)

    assert_in_delta 3.0, priced.cost.input
    # 60 short tokens at 3.75 plus 40 long tokens at 2 x 3.0, per million.
    assert_in_delta ((3.75 * 60) + (6.0 * 40)) / 1_000_000, priced.cost.cache_write
    assert_in_delta priced.cost.input + priced.cost.cache_write, priced.cost.total
  end

  def test_nonzero_costs_survive_a_json_round_trip
    usage = Mistri::Usage.new(input: 10, output: 5, cache_write: 100, cache_write_1h: 40)
                         .with_cost(input: 3.0, output: 15.0, cache_write: 3.75)

    assert_equal usage, Mistri::Usage.from_h(JSON.parse(JSON.generate(usage.to_h)))
  end
end
