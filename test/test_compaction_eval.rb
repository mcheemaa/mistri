# frozen_string_literal: true

require_relative "test_helper"
require_relative "../eval/compaction"

# The eval must be deterministic where it can be and honest where it cannot:
# the same seed builds the same history, every fact lands where the cut will
# summarize it, and grading follows the rules the README states.
class TestCompactionEval < Minitest::Test
  SCENARIO = CompactionEval::Scenario["ledger_export"]

  def test_scenarios_load_with_probes_latest_values_and_continuations
    CompactionEval::Scenario.names.each do |name|
      scenario = CompactionEval::Scenario[name]

      assert_operator(scenario.probes.length, :>=, scenario.facts.count { |f| !f.change? })
      refute_nil scenario.continuation
      assert_kind_of Hash, scenario.continuation.expected.call(scenario.latest)
    end
    latest = SCENARIO.latest

    assert_equal "exports/q3_ledger_2026-09-05_v8.csv", latest[:filename]
    assert_equal "FINAL", latest[:dedupe]
    assert_equal "Thursday 15:00 PT", latest[:cutoff]
    assert_equal "Friday 17:00 PT", SCENARIO.latest(through: 0)[:cutoff]
  end

  def test_a_changed_fact_probes_for_its_latest_value_and_its_own_question
    probes = SCENARIO.probes(through: 0)
    filename = probes.find { |probe| probe.key == :filename }
    changed = probes.find { |probe| probe.key == :filename_v2 }

    assert_equal "exports/q3_ledger_2026-09-05_v8.csv", filename.answer
    assert_predicate filename, :changed
    assert_equal "yes", changed.answer
    assert_equal :yes_no, changed.match
  end

  def test_the_same_seed_builds_the_same_history
    first = CompactionEval::Builder.new(SCENARIO, size: "S", seed: 7).build.messages
    second = CompactionEval::Builder.new(SCENARIO, size: "S", seed: 7).build.messages
    other = CompactionEval::Builder.new(SCENARIO, size: "S", seed: 8).build.messages

    assert_equal first.map(&:text), second.map(&:text)
    refute_equal first.map(&:text), other.map(&:text)
    assert_equal CompactionEval::Builder::TURNS.fetch("S") * 4, first.length
  end

  def test_every_fact_is_summarized_and_a_deep_fact_is_truncated_away
    builder = CompactionEval::Builder.new(SCENARIO, size: "S", seed: 1)
    session = builder.build
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Checkpoint." }])
    settings = Mistri::Compaction.new(keep_recent: CompactionEval::Builder::KEEP_RECENT)

    Mistri::Compactor.call(session:, provider:, settings:)

    kept_from = session.last_compaction.fetch("kept_from")
    prompt = provider.requests.first[:messages].first.text

    assert_empty builder.facts_kept(kept_from)
    assert_includes prompt, 'PG::UndefinedColumn: column "team_group_id" does not exist'
    refute_includes prompt, "439597", "a deep fact must sit inside the truncated middle"
    assert_includes prompt, "SEND-2831"
  end

  def test_grading_follows_the_documented_rules
    grader = CompactionEval::Grader

    assert grader.pass?("The file is `exports/q3_ledger_2026-09-05_v8.csv`.",
                        "exports/q3_ledger_2026-09-05_v8.csv", :contains)
    assert grader.pass?("Two decimal places.", %w[two 2], :contains)
    assert grader.pass?("No. The token must never be logged.", "no", :yes_no)
    refute grader.pass?("It should not appear in logs.", "no", :yes_no)
    assert grader.pass?("5433.", "5433", :exact)
    refute grader.pass?("54331", "5433", :exact)
    assert grader.same?("3948820.57", "$3,948,820.57")
    assert grader.same?("60.00", "$60")
    refute grader.same?("54331", "5433")
    assert grader.same?("October 9, 2026", "October 9")
    assert grader.same?("Notebook bundle", "notebook bundle")
    refute grader.same?("October 19", "October 9, 2026")
    assert grader.literal?("## Goal\nShip SEND-2831", "SEND-2831")
  end

  def test_the_runner_measures_probes_continuation_and_cost_from_the_compacted_context
    arguments = {
      "filename" => "exports/q3_ledger_2026-09-05_v8.csv",
      "footer" => "Prepared by Ada Lovelace for Finance (do not distribute)",
      "header_amount" => "$3,948,820.57", "replica_port" => "5433"
    }
    scripted = ScriptedModel.new(known: %w[SEND-2831 payments_ledger 5433],
                                 continuation: arguments)
    landed = []
    runner = CompactionEval::Runner.new(models: ["scripted"], scenarios: ["ledger_export"],
                                        sizes: ["S"], provider_for: ->(_) { scripted },
                                        io: StringIO.new, on_row: ->(row) { landed << row })

    rows = runner.run
    row = rows.first

    assert_equal 1, rows.length
    assert_equal rows, landed
    assert_equal "compacted", row[:mode]
    assert row.dig(:compactions, 0, :accepted)
    assert_equal(3, row[:probes].count { |probe| probe[:pass] })
    assert_in_delta 3.0 / SCENARIO.probes(through: 0).length, row[:probe_accuracy], 0.001
    assert row.dig(:continuation, :success), "continuation: #{row[:continuation].inspect}"
    assert_in_delta(0.0, row[:accuracy_by_carrier]["tool_deep"])
    assert_operator row[:literal_recall], :>, 0
    assert_equal CompactionEval::Runner.prompt_digest, row[:prompt_digest]
    assert_includes CompactionEval::Report.markdown(rows),
                    "| scripted | ledger_export | S | compacted |"
  end

  def test_compare_reports_deltas_and_flags_regressions
    base = [{ model: "m", scenario: "s", size: "S", mode: "compacted", probe_accuracy: 0.9,
              changed_accuracy: 1.0, continuation: { success: true },
              compactions: [{ summary_tokens: 700 }],
              git_sha: "a", prompt_digest: "p1" }]
    candidate = [base.first.merge(probe_accuracy: 0.8, git_sha: "b", prompt_digest: "p2")]

    report = CompactionEval::Report.compare(base, candidate)

    assert_includes report, "| m | s | S | compacted | -10 pts |"
    assert_includes report, "regressions beyond 5 points: m s S compacted"
  end

  # A model that knows some facts and nothing else: its summary lists the
  # known values, its probe answers are the known value or "unknown", and its
  # continuation calls the tool with the given arguments.
  class ScriptedModel
    attr_reader :requests

    def initialize(known:, continuation:)
      @known = known
      @continuation = continuation
      @requests = []
    end

    def model = "scripted"

    def stream(messages:, system: nil, tools: [], **)
      @requests << { messages: messages, system: system, tools: tools }
      return summary if system == Mistri::Compactor::SUMMARIZER_SYSTEM
      return tool_call(tools.first) if tools.any?

      question = messages.last.text
      value = @known.find { |candidate| question =~ probe_pattern(candidate) }
      Mistri::Message.assistant(content: value || "unknown", stop_reason: :stop,
                                usage: priced(100, 5))
    end

    private

    def summary
      text = "## Goal\nKnown: #{@known.join(", ")}\n## Critical Context\n- none"
      Mistri::Message.assistant(content: text, stop_reason: :stop, usage: priced(5_000, 40))
    end

    # Tools reach a provider as specs, hashes with a name, not Tool objects.
    def tool_call(tool)
      name = tool[:name] || tool["name"]
      call = Mistri::ToolCall.new(id: "continue_1", name: name, arguments: @continuation)
      Mistri::Message.assistant(content: [call], stop_reason: :tool_use,
                                usage: priced(100, 20))
    end

    def priced(input, output)
      Mistri::Usage.new(input: input, output: output).with_cost(input: 1.0, output: 5.0)
    end

    # Which probe asks for which value, keyed on words unique to its question.
    def probe_pattern(value)
      { "SEND-2831" => /ticket id/, "payments_ledger" => /table must you not touch/,
        "5433" => /port does the read replica/ }.fetch(value)
    end
  end
end
