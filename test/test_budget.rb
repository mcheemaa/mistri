# frozen_string_literal: true

require_relative "test_helper"

class TestBudget < Minitest::Test
  def test_an_empty_budget_never_stops_a_run
    budget = Mistri::Budget.new

    assert_predicate budget, :none?
    assert_nil budget.exceeded(turns: 999, usage: Mistri::Usage.zero, elapsed: 99_999)
    refute_predicate budget, :cost?
  end

  def test_each_ceiling_reports_its_own_reason
    usage = Mistri::Usage.new(input: 900, output: 200).with_cost(input: 3.0, output: 15.0)

    assert_equal :turns, Mistri::Budget.new(turns: 3).exceeded(turns: 3, usage: usage)
    assert_equal :tokens, Mistri::Budget.new(tokens: 1000).exceeded(turns: 0, usage: usage)
    assert_equal :cost, Mistri::Budget.new(cost_usd: 0.005).exceeded(turns: 0, usage: usage)
    assert_equal :wall_clock,
                 Mistri::Budget.new(wall_clock: 60).exceeded(turns: 0, usage: usage, elapsed: 61)
    assert_nil Mistri::Budget.new(turns: 4, cost_usd: 0.006).exceeded(turns: 3, usage: usage)
    assert_predicate Mistri::Budget.new(cost_usd: 1), :cost?
  end

  def test_a_cost_ceiling_rejects_unknown_cost
    budget = Mistri::Budget.new(cost_usd: 1)

    assert_raises(Mistri::BudgetError) do
      budget.exceeded(turns: 0, usage: Mistri::Usage.new(input: 1))
    end
  end
end
