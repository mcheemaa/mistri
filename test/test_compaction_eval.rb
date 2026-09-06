# frozen_string_literal: true

require_relative "test_helper"
require_relative "../eval/compaction"

# The eval must be deterministic where it can be and honest where it cannot:
# the same seed builds the same history, every fact lands where the cut will
# summarize it, and grading follows the rules the README states.
class TestCompactionEval < Minitest::Test
  SCENARIO = CompactionEval::Scenario["ledger_export"]
  ARGUMENTS = { "filename" => "exports/q3_payouts_ledger_2026-09-05_v8.csv",
                "footer" => "Prepared by Nell Adeyemi for Finance (do not distribute)",
                "header_amount" => "$3,948,820.57", "replica_port" => "5433" }.freeze
  VERDICT = '{"unsupported_claims":[{"claim":"the cutoff is Monday","reason":"never said"}],' \
            '"resumability":4,"rationale":"one invented value"}'

  def test_scenarios_load_with_probes_latest_values_continuations_and_digests
    CompactionEval::Scenario.names.each do |name|
      scenario = CompactionEval::Scenario[name]

      assert_operator(scenario.probes.length, :>=, scenario.facts.count { |f| !f.change? })
      refute_nil scenario.continuation
      assert_kind_of Hash, scenario.continuation.expected.call(scenario.latest)
      assert_match(/\A\h{12}\z/, scenario.digest)
    end
    latest = SCENARIO.latest

    assert_equal "exports/q3_payouts_ledger_2026-09-05_v8.csv", latest[:filename]
    assert_equal "FINAL", latest[:dedupe]
    assert_equal "Thursday 15:00 ET", latest[:cutoff]
    assert_equal "Friday 17:00 ET", SCENARIO.latest(through: 0)[:cutoff]
    refute_equal SCENARIO.digest, CompactionEval::Scenario["account_research"].digest
  end

  def test_a_changed_fact_probes_for_its_latest_value_and_its_own_question
    probes = SCENARIO.probes(through: 0)
    filename = probes.find { |probe| probe.key == :filename }
    changed = probes.find { |probe| probe.key == :filename_v2 }

    assert_equal "exports/q3_payouts_ledger_2026-09-05_v8.csv", filename.answer
    assert_predicate filename, :changed
    assert_equal "yes", changed.answer
    assert_equal :yes_no, changed.match
  end

  def test_the_same_seed_builds_the_same_history_with_rotating_shapes_and_failures
    first = CompactionEval::Builder.new(SCENARIO, size: "S", seed: 7).build.messages
    second = CompactionEval::Builder.new(SCENARIO, size: "S", seed: 7).build.messages
    other = CompactionEval::Builder.new(SCENARIO, size: "S", seed: 8).build.messages
    tools = first.select(&:tool?)

    assert_equal first.map(&:text), second.map(&:text)
    refute_equal first.map(&:text), other.map(&:text)
    assert_equal CompactionEval::Builder::TURNS.fetch("S") * 4, first.length
    assert_operator tools.map(&:tool_name).uniq.length, :>, 1, "filler shapes must rotate"
    assert(tools.any? { |result| result.text.start_with?("error:") }, "some tool calls must fail")
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
    assert_includes prompt, 'PG::UndefinedColumn: column "merchant_group_id" does not exist'
    assert_includes prompt, "FIN-2831"
    refute_includes prompt, "439597", "a deep fact must sit inside the truncated middle"
  end

  def test_grading_follows_the_documented_rules
    grader = CompactionEval::Grader

    assert grader.pass?("The file is `exports/q3_payouts_ledger_2026-09-05_v8.csv`.",
                        "exports/q3_payouts_ledger_2026-09-05_v8.csv", :contains)
    assert grader.pass?("Two decimal places.", %w[two 2], :contains)
    assert grader.pass?("No. The token must never be logged.", "no", :yes_no)
    refute grader.pass?("It should not appear in logs.", "no", :yes_no)
    assert grader.pass?("5433.", "5433", :exact)
    refute grader.pass?("54331", "5433", :exact)
    assert grader.pass?("argMax was double-counting refunds.", "double count", :contains)
    assert grader.pass?("184203 rows", "184,203", :contains)
    assert grader.same?("3948820.57", "$3,948,820.57")
    assert grader.same?("60.00", "$60")
    refute grader.same?("54331", "5433")
    assert grader.same?("October 9, 2026", "October 9")
    assert grader.same?("Notebook bundle", "notebook bundle")
    refute grader.same?("October 19", "October 9, 2026")
    assert grader.literal?("## Goal\nShip FIN-2831", "FIN-2831")
  end

  def test_the_runner_measures_probes_continuation_and_cost_from_the_compacted_context
    scripted = ScriptedModel.new(known: %w[FIN-2831 payouts_ledger 5433], continuation: ARGUMENTS)
    landed = []
    runner = CompactionEval::Runner.new(models: ["scripted"], scenarios: ["ledger_export"],
                                        sizes: ["S"], provider_for: ->(_) { scripted },
                                        io: StringIO.new, judge: nil,
                                        on_row: ->(row) { landed << row })

    rows = runner.run
    row = rows.first

    assert_equal 1, rows.length
    assert_equal rows, landed
    assert_equal "compacted", row[:mode]
    assert row.dig(:compactions, 0, :accepted)
    assert_equal(3, row[:probes].count { |probe| probe[:pass] })
    assert_in_delta 3.0 / SCENARIO.probes(through: 0).length, row[:probe_accuracy], 0.001
    assert row.dig(:continuation, :success), "continuation: #{row[:continuation].inspect}"
    assert row.dig(:continuation, :called)
    assert_in_delta(0.0, row[:accuracy_by_carrier]["tool_deep"])
    assert_operator row[:literal_recall], :>, 0
    assert_equal CompactionEval::Runner.prompt_digest, row[:prompt_digest]
    assert_equal SCENARIO.digest, row[:scenario_digest]
    assert_nil row[:judge]
    assert_includes CompactionEval::Report.markdown(rows),
                    "| scripted | ledger_export | S | compacted |"
  end

  def test_a_fixed_reader_answers_the_probes_and_the_judge_audits_the_summary
    summarizer = ScriptedModel.new(known: %w[FIN-2831], continuation: ARGUMENTS)
    reader = ScriptedModel.new(known: %w[FIN-2831 5433], continuation: ARGUMENTS)
    judge = Mistri::Providers::Fake.new(turns: [{ text: VERDICT }])
    providers = { "summarizer" => summarizer, "reader" => reader, "gpt-6-astra" => judge }
    runner = CompactionEval::Runner.new(models: ["summarizer"], scenarios: ["ledger_export"],
                                        sizes: ["S"], provider_for: ->(m) { providers.fetch(m) },
                                        io: StringIO.new, reader: "reader")

    row = runner.run.first

    assert_equal 1, summarizer.requests.length, "the summarizer only writes the summary"
    assert_operator reader.requests.length, :>, 1, "the reader answers every probe"
    assert_equal "reader", row[:reader]
    assert_equal(2, row[:probes].count { |probe| probe[:pass] })
    assert_equal "gpt-6-astra", row.dig(:judge, :model)
    assert_equal 1, row.dig(:judge, :unsupported)
    assert_equal 4, row.dig(:judge, :resumability)
    assert_equal "the cutoff is Monday", row.dig(:judge, :claims, 0, "claim")
    assert_includes judge.requests.first[:messages].first.text, "<conversation>"
    assert_includes judge.requests.first[:messages].first.text, "<summary>"
    assert_includes CompactionEval::Report.markdown([row]),
                    'judge flagged "the cutoff is Monday" (never said)'
    assert_includes CompactionEval::Report.markdown([row]), "| 0% | 100% |"
  end

  def test_astra_is_never_its_own_judge
    runner = CompactionEval::Runner.new(models: [], scenarios: [], sizes: [])

    assert_equal "gpt-6-astra", runner.send(:judge_for, "claude-sonnet-5")
    assert_equal "gpt-5.6-sol", runner.send(:judge_for, "gpt-6-astra")
    assert_equal "claude-opus-5",
                 CompactionEval::Runner.new(models: [], scenarios: [], sizes: [],
                                            judge: "claude-opus-5").send(:judge_for, "x")
  end

  def test_distill_keeps_scores_and_drops_every_generated_word
    row = { mode: "compacted", compactions: [{ accepted: true, summary: "secret text",
                                               summary_tokens: 10 }],
            probes: [{ key: :ticket, carrier: :user, segment: 0, changed: false, match: "contains",
                       pass: true, literal: true, stop_reason: "stop", question: "q?",
                       answer: "FIN-2831", reply: "FIN-2831" }],
            continuation: { success: true, called: true, matched: ["a"], status: "completed",
                            cost: 0.1, expected: { "a" => "x" }, actual: { "a" => "x" } },
            judge: { model: "gpt-6-astra", unsupported: 1, resumability: 4, status: "completed",
                     cost: 0.2, claims: [{ "claim" => "secret" }], rationale: "secret" } }

    distilled = CompactionEval::Runner.distill(row)

    refute_includes JSON.generate(distilled), "secret"
    refute_includes JSON.generate(distilled), "FIN-2831"
    assert_equal 10, distilled.dig(:compactions, 0, :summary_tokens)
    assert distilled.dig(:probes, 0, :pass)
    assert distilled.dig(:continuation, :success)
    assert_equal 4, distilled.dig(:judge, :resumability)
  end

  def test_regrade_recomputes_scores_from_stored_replies
    row = { mode: "compacted", compactions: [{ summary: "Ship FIN-2831 by Friday" }],
            probes: [{ key: :ticket, carrier: :user, segment: 0, changed: false, match: "contains",
                       answer: "FIN-2831", reply: "FIN-2831", pass: false, stop_reason: "stop" },
                     { key: :day, carrier: :user, segment: 0, changed: true, match: "contains",
                       answer: "Friday", reply: "Thursday", pass: true, stop_reason: "stop" }],
            continuation: { expected: { "day" => "Friday" }, actual: { "day" => "friday" },
                            matched: [], success: false, called: true } }

    regraded = CompactionEval::Runner.regrade(row)

    assert_equal([true, false], regraded[:probes].map { |probe| probe[:pass] })
    assert_in_delta 0.5, regraded[:probe_accuracy]
    assert_in_delta 0.0, regraded[:changed_accuracy]
    assert_in_delta 1.0, regraded[:literal_recall], 0.001, "both answers sit in the summary text"
    assert regraded.dig(:continuation, :success)
  end

  def test_compare_reads_per_model_aggregates_flags_real_drops_and_skips_changed_scenarios
    probes = ->(passes) { passes.map { |pass| { pass: pass, changed: false } } }
    row = { model: "m", scenario: "s", size: "S", mode: "compacted", changed_accuracy: 1.0,
            continuation: { success: true }, compactions: [{ summary_tokens: 700 }],
            git_sha: "a", prompt_digest: "p1", scenario_digest: "d1" }
    base = [row.merge(probe_accuracy: 0.9, probes: probes.call(([true] * 9) + [false]))]
    candidate = [row.merge(probe_accuracy: 0.8, probes: probes.call(([true] * 8) + ([false] * 2)),
                           git_sha: "b", prompt_digest: "p2")]
    noise = [row.merge(probe_accuracy: 0.88, probes: probes.call(([true] * 88) + ([false] * 12)))]
    steady = [row.merge(probe_accuracy: 0.9, probes: probes.call(([true] * 90) + ([false] * 10)))]
    edited = [candidate.first.merge(scenario_digest: "d2")]

    report = CompactionEval::Report.compare(base, candidate)

    assert_includes report, "| m | 90% → 80% (-10 pts) |"
    assert_includes report, "| m | s | S | compacted | -10 pts |"
    assert_includes report, "drops more than 3 points: m."
    assert_includes CompactionEval::Report.compare(steady, noise),
                    "No model loses more than 3 points"
    assert_includes CompactionEval::Report.compare(base, edited), "changed since the baseline"
    refute_includes CompactionEval::Report.compare(base, edited), "-10 pts"
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
      Mistri::Message.assistant(content: [call], stop_reason: :tool_use, usage: priced(100, 20))
    end

    def priced(input, output)
      Mistri::Usage.new(input: input, output: output).with_cost(input: 1.0, output: 5.0)
    end

    # Which probe asks for which value, keyed on words unique to its question.
    def probe_pattern(value)
      { "FIN-2831" => /ticket id/, "payouts_ledger" => /table must you not touch/,
        "5433" => /port does the read replica/ }.fetch(value)
    end
  end
end
