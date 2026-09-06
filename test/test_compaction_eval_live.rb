# frozen_string_literal: true

require_relative "test_helper"
require_relative "../eval/compaction"

# One small cell of the eval against a real model: the harness must compact,
# probe, continue, and price a run end to end.
class TestCompactionEvalLive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?
  end

  def test_one_cell_runs_end_to_end_on_haiku
    runner = CompactionEval::Runner.new(models: ["claude-haiku-4-5"], scenarios: ["ledger_export"],
                                        sizes: ["S"], io: StringIO.new)

    row = runner.run.first

    assert row.dig(:compactions, 0, :accepted), "rejected: #{row.dig(:compactions, 0, :reason)}"
    assert_empty row.dig(:compactions, 0, :facts_kept)
    assert_operator row[:probe_accuracy], :>=, 0.5
    assert_kind_of Hash, row[:continuation]
    assert_operator CompactionEval::Report.total_cost(row), :>, 0
    assert_equal 0, row[:unpriced]
  end
end
