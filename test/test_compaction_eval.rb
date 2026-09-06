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
    refute grader.pass?("10.3%", "0.3%", :contains)
    refute grader.pass?("port 54331", "5433", :contains)
    assert grader.pass?("The rate is 0.3% now.", "0.3%", :contains)
    assert grader.pass?("Port 5433.", "5433", :contains)
  end

  def test_tool_arguments_compare_as_values_with_digit_boundaries
    grader = CompactionEval::Grader

    assert grader.same?("3948820.57", "$3,948,820.57")
    assert grader.same?("60.00", "$60")
    refute grader.same?("54331", "5433")
    assert grader.same?("October 9, 2026", "October 9")
    refute grader.same?("10.3%", "0.3%")
    refute grader.same?("54331/tcp", "5433")
    refute grader.same?("13948820.57 USD", "$3,948,820.57")
    assert grader.same?("3,948,820.57 USD", "$3,948,820.57")
    assert grader.pass?("Root cause: PO box addresses arrive with a nil street line.",
                        ["PO box", "nil street"], :contains)
    refute grader.pass?("connection pooling exhausted", ["PO box", "nil street"], :contains)
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

  def test_compare_matches_cells_refuses_the_incomparable_and_flags_real_drops
    probes = ->(passes) { passes.map { |pass| { pass: pass, changed: false } } }
    row = { model: "m", scenario: "s", size: "S", mode: "compacted", reader: nil, folds: 2,
            changed_accuracy: 1.0, continuation: { success: true },
            compactions: [{ summary_tokens: 700 }], git_sha: "a", prompt_digest: "p1",
            scenario_digest: "d1", grader_version: CompactionEval::Grader::VERSION }
    base_s = row.merge(probe_accuracy: 0.9, probes: probes.call(([true] * 9) + [false]))
    base_m = row.merge(size: "M", probe_accuracy: 0.5, probes: probes.call([true, false]))
    worse_s = row.merge(probe_accuracy: 0.8, probes: probes.call(([true] * 8) + ([false] * 2)),
                        git_sha: "b", prompt_digest: "p2")

    against_mixed = CompactionEval::Report.compare([base_s, base_m], [worse_s])

    refute_predicate against_mixed, :passed, "an S-only candidate must be judged on the S cell"
    assert_includes against_mixed.markdown, "| m | 90% -> 80% (-10 pts) |"
    assert_includes against_mixed.markdown, "Baseline cells the candidate did not run"
    assert_includes CompactionEval::Report.compare([base_s], [base_s, base_m]).markdown,
                    "Candidate cells with no baseline"
    refute_predicate CompactionEval::Report.compare([base_s], []), :passed
    assert_includes CompactionEval::Report.compare([base_s], []).markdown, "no rows"
    old_grader = [base_s.merge(grader_version: "old")]

    refute_predicate CompactionEval::Report.compare([base_s], old_grader), :passed
    assert_includes CompactionEval::Report.compare([base_s], [base_s.merge(scenario_digest: "d2")])
                                          .markdown, "changed since the baseline"
  end

  def test_compare_counts_rejections_and_lets_noise_through
    probes = ->(passes) { passes.map { |pass| { pass: pass, changed: false } } }
    row = { model: "m", scenario: "s", size: "S", mode: "compacted", reader: nil, folds: 2,
            changed_accuracy: 1.0, continuation: { success: true },
            compactions: [{ summary_tokens: 700 }], git_sha: "a", prompt_digest: "p1",
            scenario_digest: "d1", grader_version: CompactionEval::Grader::VERSION }
    base = [row.merge(probe_accuracy: 0.9, probes: probes.call(([true] * 9) + [false]))]
    rejected = [row.merge(skipped: "compaction rejected")]
    noise = [row.merge(probe_accuracy: 0.88, probes: probes.call(([true] * 88) + ([false] * 12)))]
    steady = [row.merge(probe_accuracy: 0.9, probes: probes.call(([true] * 90) + ([false] * 10)))]

    assert_includes CompactionEval::Report.compare(base, rejected).markdown,
                    "m (rejected compactions)"
    refute_predicate CompactionEval::Report.compare(base, rejected), :passed
    assert_predicate CompactionEval::Report.compare(steady, noise), :passed
  end

  # A model that knows some facts and nothing else: its summary lists the
  # known values, its probe answers are the known value or "unknown", and its
  # continuation calls the tool with the given arguments.
  class ScriptedModel
    attr_reader :requests

    def initialize(known:, continuation:, calls: 1)
      @known = known
      @continuation = continuation
      @calls = calls
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
      calls = Array.new(@calls) do |index|
        Mistri::ToolCall.new(id: "continue_#{index + 1}", name: name, arguments: @continuation)
      end
      Mistri::Message.assistant(content: calls, stop_reason: :tool_use, usage: priced(100, 20))
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

# The parts of the eval that only a paid run exercised so far: every filler
# shape and generator, the runner's failure paths, baselines and folds, and the
# command-line wiring. Hermetic, with scripted providers.
class TestCompactionEvalPaths < Minitest::Test
  SUMMARY = "## Goal\nKnown: FIN-2831, INC-4471, CMP-8842\n## Critical Context\n- none"

  def test_every_scenario_builds_at_every_size_with_all_of_its_shapes
    CompactionEval::Scenario.names.each do |name|
      scenario = CompactionEval::Scenario[name]
      messages = CompactionEval::Builder.new(scenario, size: "M", seed: 3).build.messages
      tools = messages.select(&:tool?)
      shapes = messages.select { |m| m.assistant? && m.tool_calls? }
                       .map { |m| m.text.to_s.gsub(/\d+/, "N") }.uniq

      assert_operator shapes.length, :>=, 4, "#{name} rotates its shapes"
      assert_operator tools.count { |result| result.text.start_with?("error:") }, :>=, 5
      assert_operator tools.reject { |result| result.text.start_with?("error:") }
                           .map { |result| result.text.length }.min, :>, 1_000
    end
    session = CompactionEval::Builder.new(CompactionEval::Scenario["ledger_export"], size: "S",
                                                                                     seed: 1)
    session.append_segment(session.build, 1)

    assert_raises(ArgumentError) { CompactionEval::Builder.new(nil, size: "XL", seed: 1) }
  end

  def test_the_tail_session_holds_only_what_the_cut_keeps
    builder = CompactionEval::Builder.new(CompactionEval::Scenario["ledger_export"], size: "S",
                                                                                     seed: 1)
    session = builder.build
    tail = builder.tail_session(session)

    assert_equal CompactionEval::Builder::TAIL_TURNS * 4, tail.messages.length
    assert_equal session.messages.last.text, tail.messages.last.text
    assert_equal builder.fact_entries.keys.sort, builder.facts_kept(0).sort
  end

  def test_scenario_definitions_are_validated
    define = lambda do |&block|
      CompactionEval::Scenario.build("invalid", summary: "x", &block)
    end
    filler = ->(_turn, _rng) { {} }
    finish = lambda do |scenario|
      scenario.continuation(prompt: "p", tool: "t", description: "d", schema: -> {},
                            expected: ->(_) { {} })
    end

    assert_raises(ArgumentError) { define.call { filler(&filler) } }
    error = assert_raises(ArgumentError) do
      define.call do
        filler(&filler)
        finish.call(self)
        segment { fact :a, "1", at: 0.1, text: "%<value>s", probe: "?" }
        segment { fact :a, "2", at: 0.1, text: "%<value>s", probe: "?" }
      end
    end

    assert_match(/repeats fact keys/, error.message)
    error = assert_raises(ArgumentError) do
      define.call do
        filler(&filler)
        finish.call(self)
        segment { change :ghost, "2", at: 0.1, text: "%<value>s" }
      end
    end

    assert_match(/supersedes unknown/, error.message)
    assert_raises(ArgumentError) do
      CompactionEval::Fact.new(key: :a, value: "1", text: "x", at: 0.95, probe: "?")
    end
    assert_raises(ArgumentError) do
      CompactionEval::Fact.new(key: :a, value: "1", text: "x", at: 0.1, probe: "?", carrier: :sms)
    end
  end

  def test_a_rejected_compaction_skips_the_row_and_the_report_says_so
    provider = Mistri::Providers::Fake.new(turns: [{ text: "cut", stop_reason: :length }])
    runner = CompactionEval::Runner.new(models: ["fake"], scenarios: ["incident_debugging"],
                                        sizes: ["S"], provider_for: ->(_) { provider },
                                        io: StringIO.new, judge: nil)

    row = runner.run.first

    assert_equal "compaction rejected", row[:skipped]
    refute row.dig(:compactions, 0, :accepted)
    assert_match(/summarization failed/, row.dig(:compactions, 0, :reason))
    assert_includes CompactionEval::Report.line(row), "skipped"
    assert_includes CompactionEval::Report.markdown([row]), "All probes passed."
  end

  def test_baselines_and_folds_measure_the_full_history_the_tail_and_later_segments
    scripted = Scripted.new
    runner = CompactionEval::Runner.new(models: ["scripted"], scenarios: ["account_research"],
                                        sizes: ["S"], provider_for: ->(_) { scripted },
                                        io: StringIO.new, judge: nil, folds: true, baselines: true)

    rows = runner.run
    compacted, full, tail = rows

    assert_equal(%w[compacted full tail], rows.map { |row| row[:mode] })
    assert_equal 2, compacted[:folds]
    assert_equal %w[0 1], compacted[:accuracy_by_segment].keys
    assert_nil full[:literal_recall]
    assert_nil tail[:compactions]
    assert_equal 18, compacted[:probes].length
    assert_includes CompactionEval::Report.markdown(rows),
                    "| scripted | account_research | S | tail |"
  end

  def test_transient_probe_errors_are_retried_and_judge_failures_are_recorded
    flaky = Scripted.new(errors_before_answer: 1)
    broken_judge = Mistri::Providers::Fake.new
    broken_judge.define_singleton_method(:stream) { |**| raise IOError, "judge unreachable" }
    providers = { "scripted" => flaky, "gpt-6-astra" => broken_judge }
    runner = CompactionEval::Runner.new(models: ["scripted"], scenarios: ["ledger_export"],
                                        sizes: ["S"], provider_for: ->(m) { providers.fetch(m) },
                                        io: StringIO.new, pause: 0)

    row = runner.run.first

    assert_operator flaky.retried, :>, 0
    assert_operator row[:probe_accuracy], :>, 0
    retried_probe = row[:probes].first

    assert_in_delta 0.000201, retried_probe[:cost], 0.000001, "both attempts are paid for"
    assert_match(/error: IOError/, row.dig(:judge, :status))
    assert_nil row.dig(:judge, :cost)
    assert_operator row[:unpriced], :>=, 1
  end

  def test_the_command_line_lists_scenarios_and_rewrites_result_files
    require_relative "../script/compaction_eval"
    cli = CompactionEval::CLI.new
    rows = [{ model: "m", scenario: "s", size: "S", mode: "compacted", rep: 0, probe_accuracy: 1.0,
              grader_version: CompactionEval::Grader::VERSION,
              probes: [{ key: :k, carrier: :user, segment: 0, changed: false, match: "contains",
                         answer: "v", reply: "v", pass: true, stop_reason: "stop" }],
              compactions: [{ accepted: true, summary: "text", summary_tokens: 3,
                              tokens_before: 900, tokens_after: 300 }],
              continuation: { success: false, called: 1, matched: [], wrong: ["a"],
                              expected: { "a" => "x" }, actual: { "a" => "y" } } },
            { model: "m", scenario: "s", size: "S", mode: "compacted", rep: 1, probe_accuracy: 1.0,
              grader_version: CompactionEval::Grader::VERSION, probes: [],
              compactions: [{ accepted: true, summary: "text", summary_tokens: 3 }],
              continuation: { success: false, called: 0, matched: [], wrong: ["a"],
                              expected: { "a" => "x" }, actual: nil, status: "no tool call" } }]

    listed = capture_io { cli.start(["list"]) }.first
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rows.jsonl")
      CompactionEval::Report.write(rows, path)
      out = File.join(dir, "baselines", "current.jsonl")
      capture_io { cli.start(["distill", path, out]) }
      regraded = File.join(dir, "regraded.jsonl")
      capture_io { cli.start(["regrade", path, regraded]) }
      reported = capture_io { cli.start(["report", path]) }.first
      compared = capture_io { cli.start(["compare", path, regraded]) }.first
      failing = File.join(dir, "failing.jsonl")
      CompactionEval::Report.write([rows.first.merge(probe_accuracy: 0.0, probes: [])], failing)

      refute_includes File.read(out), "text"
      assert_path_exists out.sub(".jsonl", ".md")
      assert_includes File.read(regraded), '"pass":true'
      assert_includes reported, "| m | s | S | compacted |"
      assert_includes compared, "Passed"
      assert_raises(SystemExit) { capture_io { cli.start(["compare", path, failing]) } }
    end

    assert_includes listed, "ledger_export"
    assert_raises(SystemExit) { capture_io { cli.start(["bogus"]) } }
  end

  def test_the_command_line_runs_a_matrix_end_to_end_and_loads_keys_from_the_env_file
    require_relative "../script/compaction_eval"
    scripted = TestCompactionEval::ScriptedModel.new(known: %w[FIN-2831], continuation: TestCompactionEval::ARGUMENTS)
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "env")
      File.write(env_file, "# keys\n\nexport EVAL_TEST_KEY=\"from-file\"\n")
      prompts = File.join(dir, "prompts.rb")
      File.write(prompts, "# a local prompt override would live here\n")
      out = File.join(dir, "run", "rows.jsonl")
      cli = CompactionEval::CLI.new(env_file: env_file, provider_for: ->(_) { scripted })

      printed = capture_io do
        cli.start(["run", "--models", "scripted", "--scenarios", "ledger_export", "--sizes", "S",
                   "--no-judge", "--prompts", prompts, "--out", out])
      end.first

      assert_equal "from-file", ENV.fetch("EVAL_TEST_KEY")
      assert_equal 1, File.readlines(out).length
      assert_path_exists out.sub(".jsonl", ".md")
      assert_includes printed, "| scripted | ledger_export | S | compacted |"
      assert_match(%r{tmp/compaction-eval/\d{8}T\d{6}Z-\h+\.jsonl\z}, cli.send(:default_out))
    ensure
      ENV.delete("EVAL_TEST_KEY")
    end
    listed = capture_io { CompactionEval::CLI.start(["list"]) }.first

    assert_includes listed, "incident_debugging"
  end

  def test_an_unknown_model_fails_before_any_request_and_a_broken_reader_is_recorded
    runner = CompactionEval::Runner.new(models: ["no-such-model"], scenarios: ["ledger_export"],
                                        sizes: ["S"], io: StringIO.new, judge: nil)

    assert_raises(Mistri::ConfigurationError) { runner.run }

    summarizer = TestCompactionEval::ScriptedModel.new(known: %w[FIN-2831], continuation: TestCompactionEval::ARGUMENTS)
    broken = TestCompactionEval::ScriptedModel.new(known: [], continuation: TestCompactionEval::ARGUMENTS)
    broken.define_singleton_method(:stream) do |tools: [], **|
      raise IOError, "reader unreachable" if tools.any?

      Mistri::Message.assistant(content: "unknown", stop_reason: :stop)
    end
    providers = { "summarizer" => summarizer, "broken" => broken }
    row = CompactionEval::Runner.new(models: ["summarizer"], scenarios: ["ledger_export"],
                                     sizes: ["S"], provider_for: ->(m) { providers.fetch(m) },
                                     io: StringIO.new, judge: nil, reader: "broken").run.first

    refute row.dig(:continuation, :success)
    assert_match(/error: IOError/, row.dig(:continuation, :status))
    assert_nil row.dig(:continuation, :cost)
  end

  def test_the_command_line_parses_every_option
    require_relative "../script/compaction_eval"
    cli = CompactionEval::CLI.new
    parsed = {}
    files = {}

    cli.send(:parser, parsed, files).parse!(%w[--models a,b --scenarios ledger_export --sizes S,M
                                               --repeat 2 --seed 9 --folds --baselines --reader r
                                               --judge j --no-judge --out o.jsonl])

    assert_equal %w[a b], parsed[:models]
    assert_equal ["ledger_export"], parsed[:scenarios]
    assert_equal %w[S M], parsed[:sizes]
    assert_equal 2, parsed[:repeat]
    assert_equal 9, parsed[:seed]
    assert parsed[:folds]
    assert parsed[:baselines]
    assert_equal "r", parsed[:reader]
    assert_nil parsed[:judge]
    assert_equal "o.jsonl", files[:out]
  end

  # Knows the identifiers, answers everything else with "unknown", and can be
  # asked to fail with a transient error before its first real answer.
  class Scripted
    attr_reader :requests, :retried

    def initialize(errors_before_answer: 0)
      @requests = []
      @errors = errors_before_answer
      @retried = 0
    end

    def model = "scripted"

    def stream(messages:, system: nil, tools: [], **)
      @requests << { messages: messages, system: system }
      return Mistri::Message.assistant(content: SUMMARY, stop_reason: :stop, usage: usage(4_000)) if
        system == Mistri::Compactor::SUMMARIZER_SYSTEM
      return tool_call(tools.first) if tools.any?

      if @errors.positive?
        @errors -= 1
        @retried += 1
        return Mistri::Message.assistant(content: nil, stop_reason: :error,
                                         error_message: "rate limit exceeded", usage: usage(1))
      end

      question = messages.last.text
      answer = %w[FIN-2831 INC-4471 CMP-8842].find do |id|
        question =~ /(ticket|incident|campaign) id/ && id
      end
      Mistri::Message.assistant(content: answer || "unknown", stop_reason: :stop, usage: usage(100))
    end

    private

    # Arguments that satisfy whatever schema the scenario declares, so the
    # continuation ends after one call instead of a correction loop.
    def tool_call(tool)
      name = tool[:name] || tool["name"]
      schema = tool[:input_schema] || tool["input_schema"] || {}
      properties = schema[:properties] || schema["properties"] || {}
      arguments = properties.keys.to_h { |key| [key.to_s, "x"] }
      call = Mistri::ToolCall.new(id: "c_#{@requests.length}", name: name, arguments: arguments)
      Mistri::Message.assistant(content: [call], stop_reason: :tool_use, usage: usage(50))
    end

    def usage(input)
      Mistri::Usage.new(input: input, output: 10).with_cost(input: 1.0, output: 5.0)
    end
  end
end

# The measurement contracts the second review pinned down: one call, digit
# boundaries in tool arguments, deep facts really out of the wire, the tail
# control equal to the real cut, digests that see the whole experiment, and
# regrading over the text that was graded.
class TestCompactionEvalContracts < Minitest::Test
  def test_a_continuation_must_be_called_exactly_once_with_the_agreed_values
    twice = TestCompactionEval::ScriptedModel.new(known: %w[FIN-2831],
                                                  continuation: TestCompactionEval::ARGUMENTS,
                                                  calls: 2)
    wrong = TestCompactionEval::ScriptedModel.new(
      known: %w[FIN-2831],
      continuation: TestCompactionEval::ARGUMENTS.merge("replica_port" => "54331/tcp")
    )
    runner = lambda do |model|
      CompactionEval::Runner.new(models: ["m"], scenarios: ["ledger_export"], sizes: ["S"],
                                 provider_for: ->(_) { model }, io: StringIO.new, judge: nil)
    end

    doubled = runner.call(twice).run.first[:continuation]
    mistaken = runner.call(wrong).run.first[:continuation]

    refute doubled[:success]
    assert_equal 2, doubled[:called]
    assert_equal "called 2 times", doubled[:status]
    refute mistaken[:success]
    assert_equal ["replica_port"], mistaken[:wrong]
  end

  def test_deep_facts_stay_out_of_the_summarizer_wire_in_every_scenario_and_size
    CompactionEval::Scenario.names.product(%w[S M]).each do |name, size|
      scenario = CompactionEval::Scenario[name]
      builder = CompactionEval::Builder.new(scenario, size: size, seed: 5)
      session = builder.build
      provider = Mistri::Providers::Fake.new(turns: [{ text: "Checkpoint." }])
      settings = Mistri::Compaction.new(keep_recent: CompactionEval::Builder::KEEP_RECENT)

      Mistri::Compactor.call(session:, provider:, settings:)

      prompt = provider.requests.first[:messages].first.text
      scenario.facts(through: 0).each do |fact|
        if fact.carrier == :tool_deep
          refute_includes prompt, fact.value, "#{name}/#{size} #{fact.key} must be truncated away"
        else
          assert_includes prompt, Array(fact.value).first,
                          "#{name}/#{size} #{fact.key} must be seen"
        end
      end

      assert_empty builder.facts_kept(session.last_compaction.fetch("kept_from"))
    end
  end

  def test_the_tail_control_is_exactly_what_the_cut_keeps
    builder = CompactionEval::Builder.new(CompactionEval::Scenario["account_research"], size: "S",
                                                                                        seed: 1)
    session = builder.build
    tail = builder.tail_session(session).messages
    probe = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.entries.each { |entry| probe.append(entry["type"], entry.except("type", "at")) }
    placeholder = Mistri::Providers::Fake.new(turns: [{ text: "x" }])
    settings = Mistri::Compaction.new(keep_recent: CompactionEval::Builder::KEEP_RECENT)
    Mistri::Compactor.call(session: probe, provider: placeholder, settings: settings)

    assert_equal probe.messages.drop(1).map(&:text), tail.map(&:text)
  end

  def test_scenario_digests_see_segment_placement_and_filler_changes
    build = lambda do |name, filler_word, &facts|
      CompactionEval::Scenario.build(name, summary: "x") do
        filler do |turn, _rng|
          { ask: "#{filler_word} #{turn}", doing: "d", tool: "t", arguments: {},
            log: ->(chars) { "l" * chars }, done: "done" }
        end
        instance_exec(&facts)
        continuation(prompt: "p", tool: "t", description: "d", schema: -> {},
                     expected: ->(_) { {} })
      end
    end
    one = build.call("digest-a", "ask") do
      segment { fact :a, "1", at: 0.1, text: "%<value>s", probe: "?" }
      segment { fact :b, "2", at: 0.1, text: "%<value>s", probe: "?" }
    end
    moved = build.call("digest-b", "ask") do
      segment do
        fact :a, "1", at: 0.1, text: "%<value>s", probe: "?"
        fact :b, "2", at: 0.8, text: "%<value>s", probe: "?"
      end
    end
    refilled = build.call("digest-c", "step") do
      segment { fact :a, "1", at: 0.1, text: "%<value>s", probe: "?" }
      segment { fact :b, "2", at: 0.1, text: "%<value>s", probe: "?" }
    end

    refute_equal one.digest, moved.digest
    refute_equal one.digest, refilled.digest
  end

  def test_a_long_reply_regrades_the_same_way_it_graded
    row = { mode: "compacted", compactions: [{ summary: "s" }],
            probes: [{ key: :k, carrier: :user, segment: 0, changed: false, match: "contains",
                       answer: "FIN-2831", reply: "#{"x" * 2_500} FIN-2831", pass: true,
                       stop_reason: "stop" }] }

    assert CompactionEval::Runner.regrade(row)[:probes].first[:pass]
  end
end
