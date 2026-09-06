# frozen_string_literal: true

require "json"

module CompactionEval
  # Rows in, tables out: a progress line per row while a run is going, a
  # markdown report for a results file, and a comparison between two files
  # (a baseline and a candidate prompt, usually).
  module Report
    # A cell is everything that must agree before two rows are comparable.
    KEY = %i[model scenario size mode reader folds].freeze
    COLUMNS = ["model", "scenario", "size", "mode", "probes", "changed", "deep", "continuation",
               "literal", "unsupported", "resumability", "summary tok", "before -> after",
               "compaction $", "total $"].freeze
    # Two runs of the same prompt differ by up to six points in one cell and
    # by under two points in a model's aggregate over all cells, so the
    # verdict reads the aggregate and the cell table stays informational.
    REGRESSION = 0.03

    # What a comparison concluded, and the text that says why.
    Comparison = Data.define(:markdown, :passed) do
      def to_s = markdown
    end

    module_function

    def line(row)
      head = format("%<model>-22s %<scenario>-20s %<size>s %<mode>-9s", row)
      return "#{head} skipped: #{row[:skipped]}" if row[:skipped]

      "#{head} probes #{pct(row[:probe_accuracy])}  changed #{pct(row[:changed_accuracy])}  " \
        "continuation #{row.dig(:continuation, :success) ? "ok" : "MISS"}  " \
        "summary #{summary_tokens([row])} tok  #{money(total_cost(row))}"
    end

    def write(rows, path)
      File.open(path, "w") { |file| rows.each { |row| file.puts(JSON.generate(row)) } }
    end

    # Rows written before the exactly-once continuation rule carried a boolean
    # `called`; they cannot certify one call, so they are refused rather than
    # read as if they could.
    def read(path)
      rows = File.readlines(path, chomp: true).reject(&:empty?)
                 .map { |line| JSON.parse(line, symbolize_names: true) }
      legacy = rows.any? { |row| [true, false].include?(row.dig(:continuation, :called)) }
      if legacy
        raise ArgumentError, "#{path} predates the exactly-once continuation rule; regenerate it"
      end

      rows
    end

    def markdown(rows)
      lines = ["# Compaction eval", "", header(rows), "", table(COLUMNS)]
      grouped(rows).each_value { |group| lines << table(cells(group)) }
      [*lines, "", *misses(rows)].join("\n")
    end

    # Only cells present on both sides count, graded by the same rules, on
    # the same scenarios; everything else is named, never silently passed.
    def compare(base, candidate)
      problems = incomparable(base, candidate)
      if problems.any?
        return Comparison.new(markdown: refusal(base, candidate, problems), passed: false)
      end

      changed = changed_scenarios(base, candidate)
      base_cells = grouped(base).reject { |key, _| changed.include?(key[1]) }
      candidate_cells = grouped(candidate).reject { |key, _| changed.include?(key[1]) }
      matched = base_cells.keys & candidate_cells.keys
      regressions = []
      per_model = per_model(base_cells.slice(*matched), candidate_cells.slice(*matched),
                            regressions)
      regressions << "no comparable compacted cells" if per_model.empty?
      markdown = ["# Compaction eval comparison", "", versions(base, candidate),
                  *coverage(base_cells.keys, candidate_cells.keys, changed), "",
                  "## Per model, matched compacted cells", "",
                  table(%w[model probes changed continuation unsupported resumability rejected]),
                  *per_model, "", "## Per cell", "",
                  *per_cell(base_cells, candidate_cells, matched), "",
                  verdict(regressions)].join("\n")
      Comparison.new(markdown: markdown, passed: regressions.empty?)
    end

    def incomparable(base, candidate)
      problems = []
      problems << "the candidate has no rows" if candidate.empty?
      problems << "the baseline has no rows" if base.empty?
      graders = (base + candidate).map { |row| row[:grader_version] }.uniq
      if graders.length > 1
        problems << "grader versions differ (#{graders.join(", ")}): regrade or regenerate"
      end
      problems
    end

    def refusal(base, candidate, problems)
      ["# Compaction eval comparison", "", versions(base, candidate), "",
       "Not comparable: #{problems.join("; ")}."].join("\n")
    end

    # Each cell is summarized first, then cells combine with the same weights
    # on both sides (the baseline cell's probes per repetition), so a cell
    # that ran more repetitions on one side does not count for more.
    def per_model(base_cells, candidate_cells, regressions)
      before_by_model = weighted(base_cells, base_cells)
      weighted(candidate_cells, base_cells).filter_map do |model, after|
        before = before_by_model[model]
        next unless before

        delta = after[:probes] - before[:probes]
        regressions << model if delta < -REGRESSION
        regressions << "#{model} (rejected compactions)" if after[:rejected] > before[:rejected]
        table([model, "#{pct(before[:probes])} -> #{pct(after[:probes])} (#{signed(delta)})",
               "#{pct(before[:changed])} -> #{pct(after[:changed])}",
               "#{pct(before[:continuation])} -> #{pct(after[:continuation])}",
               "#{number(before[:unsupported])} -> #{number(after[:unsupported])}",
               "#{number(before[:resumability])} -> #{number(after[:resumability])}",
               "#{pct(before[:rejected])} -> #{pct(after[:rejected])}"])
      end
    end

    def per_cell(base_cells, candidate_cells, matched)
      rows = matched.map do |key|
        before = base_cells.fetch(key)
        group = candidate_cells.fetch(key)
        table([*key.first(4), "#{before.length} -> #{group.length}",
               signed(delta_for(before, group, :probe_accuracy)),
               signed(delta_for(before, group, :changed_accuracy)),
               signed(delta_for(before, group) { |row| continued(row) }),
               "#{summary_tokens(before)} -> #{summary_tokens(group)}"])
      end
      [table(%w[model scenario size mode reps probes changed continuation] + ["summary tok"]),
       *rows]
    end

    # One summary per cell: repetitions average within the cell, and the
    # cell's weight is its probes per repetition on the baseline side.
    def cell(rows, weight_rows)
      measured = rows.reject { |row| row[:skipped] }
      weight = weight_rows.reject { |row| row[:skipped] }.first || measured.first
      { probes: mean(measured) { |row| ratio(Array(row[:probes])) },
        changed: mean(measured) { |row| ratio(Array(row[:probes]).select { |p| p[:changed] }) },
        continuation: mean(measured) { |row| continued(row) },
        unsupported: mean(measured) { |row| row.dig(:judge, :unsupported) },
        resumability: mean(measured) { |row| row.dig(:judge, :resumability) },
        rejected: rows.count { |row| row[:skipped] }.fdiv(rows.length),
        weight: weight ? Array(weight[:probes]).length : 0 }
    end

    def weighted(cells, weight_cells)
      compacted = cells.select { |key, _| key[3] == "compacted" }
      compacted.group_by { |key, _| key[0] }.to_h do |model, entries|
        summaries = entries.map { |key, rows| cell(rows, weight_cells.fetch(key, rows)) }
        [model, { probes: combine(summaries, :probes) || 0.0,
                  changed: combine(summaries, :changed) || 0.0,
                  continuation: combine(summaries, :continuation) || 0.0,
                  unsupported: combine(summaries, :unsupported),
                  resumability: combine(summaries, :resumability),
                  rejected: summaries.sum { |c| c[:rejected] }.fdiv(summaries.length) }]
      end
    end

    def combine(summaries, field)
      known = summaries.select { |c| c[field] && c[:weight].positive? }
      return nil if known.empty?

      known.sum { |c| c[field] * c[:weight] }.fdiv(known.sum { |c| c[:weight] })
    end

    def coverage(base_keys, candidate_keys, changed)
      notes = []
      unless changed.empty?
        notes << "Scenarios changed since the baseline and left out: #{changed.join(", ")}. " \
                 "Rerun the baseline to compare them."
      end
      missing = base_keys - candidate_keys
      extra = candidate_keys - base_keys
      unless missing.empty?
        notes << "Baseline cells the candidate did not run (not compared): " \
                 "#{missing.map { |key| key.first(4).join("/") }.join(", ")}."
      end
      unless extra.empty?
        notes << "Candidate cells with no baseline (not compared): " \
                 "#{extra.map { |key| key.first(4).join("/") }.join(", ")}."
      end
      notes.empty? ? [] : ["", *notes]
    end

    # A scenario edited since the baseline has no comparable rows; say so
    # instead of comparing different questions.
    def changed_scenarios(base, candidate)
      digests = ->(rows) { rows.to_h { |row| [row[:scenario].to_s, row[:scenario_digest]] } }
      before = digests.call(base)
      digests.call(candidate).filter_map do |scenario, digest|
        scenario if before.key?(scenario) && before[scenario] != digest
      end
    end

    def grouped(rows)
      rows.group_by { |row| KEY.map { |key| row[key].to_s } }
    end

    def ratio(probes)
      probes.empty? ? 0.0 : probes.count { |probe| probe[:pass] }.fdiv(probes.length)
    end

    def header(rows)
      "#{rows.length} rows, git #{rows.map { |row| row[:git_sha] }.uniq.join("/")}, prompt " \
        "#{rows.map { |row| row[:prompt_digest] }.uniq.join("/")}, grader " \
        "#{rows.map { |row| row[:grader_version] }.uniq.join("/")}, " \
        "total #{money(rows.sum { |row| total_cost(row) })}"
    end

    def versions(base, candidate)
      "baseline #{base.first&.dig(:git_sha)} (prompt #{base.first&.dig(:prompt_digest)}) vs " \
        "candidate #{candidate.first&.dig(:git_sha)} " \
        "(prompt #{candidate.first&.dig(:prompt_digest)})"
    end

    def table(cells)
      row = "| #{cells.join(" | ")} |"
      cells.equal?(COLUMNS) || cells.first == "model" ? "#{row}\n|#{"---|" * cells.length}" : row
    end

    def cells(group)
      first = group.first
      [first[:model], first[:scenario], first[:size], first[:mode],
       pct(mean(group, :probe_accuracy)), pct(mean(group, :changed_accuracy)),
       pct(mean(group) { |row| deep(row) }),
       pct(mean(group) { |row| continued(row) }), pct(mean(group, :literal_recall)),
       number(mean(group) { |row| row.dig(:judge, :unsupported) }),
       number(mean(group) { |row| row.dig(:judge, :resumability) }),
       summary_tokens(group), compression(group),
       money(mean(group) { |row| compaction_cost(row) }),
       money(mean(group) { |row| total_cost(row) })]
    end

    def misses(rows)
      failed = rows.reject { |row| row[:skipped] || row[:mode] != "compacted" }.flat_map do |row|
        probes = Array(row[:probes]).reject { |probe| probe[:pass] }.map do |probe|
          "- #{row[:model]} #{row[:scenario]} #{row[:size]}: #{probe[:key]} (#{probe[:carrier]}) " \
            "expected #{Array(probe[:answer]).first.inspect}, " \
            "got #{probe[:reply].to_s[0, 80].inspect}"
        end
        probes + continuation_miss(row) + judge_flags(row)
      end
      failed.empty? ? ["All probes passed."] : ["## Misses", "", *failed]
    end

    # Reads the distilled shape too: field names survive distilling, values
    # do not.
    def continuation_miss(row)
      continuation = row[:continuation]
      return [] if continuation.nil? || continuation[:success]

      wrong = Array(continuation[:wrong]).map(&:to_s)
      detail = if continuation[:called].to_i == 1 && wrong.any?
                 "wrong #{wrong.join(", ")}"
               else
                 continuation[:status].to_s
               end
      ["- #{row[:model]} #{row[:scenario]} #{row[:size]}: continuation #{detail}"]
    end

    # Judge claims arrive with string keys from the model and symbol keys
    # after a file round trip; both read the same here.
    def judge_flags(row)
      Array(row.dig(:judge, :claims)).map do |claim|
        text = claim[:claim] || claim["claim"]
        reason = claim[:reason] || claim["reason"]
        "- #{row[:model]} #{row[:scenario]} #{row[:size]}: judge flagged " \
          "#{text.to_s[0, 100].inspect} (#{reason.to_s[0, 80]})"
      end
    end

    def deep(row)
      carriers = row[:accuracy_by_carrier] || {}
      carriers[:tool_deep] || carriers["tool_deep"]
    end

    def verdict(regressions)
      points = (REGRESSION * 100).round
      if regressions.empty?
        return "Passed: no model loses more than #{points} points of aggregate probe accuracy " \
               "or rejects more compactions, over matched cells."
      end

      "Failed: #{regressions.join(", ")} (more than #{points} points of aggregate probe " \
        "accuracy lost, more rejected compactions, or nothing comparable)."
    end

    def mean(group, key = nil, &)
      values = group.map { |row| key ? row[key] : yield(row) }.compact
      values.empty? ? nil : values.sum.fdiv(values.length)
    end

    def delta_for(before, after, key = nil, &)
      earlier = key ? mean(before, key) : mean(before, &)
      later = key ? mean(after, key) : mean(after, &)
      earlier && later ? (later - earlier).round(3) : nil
    end

    def continued(row) = row.dig(:continuation, :success) ? 1.0 : 0.0

    def pct(value) = value.nil? ? "-" : "#{(value * 100).round}%"

    def number(value) = value.nil? ? "-" : format("%<n>.1f", n: value)

    def signed(delta) = delta.nil? ? "-" : format("%<pts>+d pts", pts: (delta * 100).round)

    def money(value) = value.nil? ? "-" : format("$%<usd>.3f", usd: value)

    # The largest summary in the cell: the bar is about size, so the worst
    # repetition is the one that matters.
    def summary_tokens(rows)
      sizes = Array(rows).filter_map { |row| row[:compactions]&.last&.dig(:summary_tokens) }
      sizes.empty? ? "-" : sizes.max
    end

    def compression(rows)
      firsts = Array(rows).filter_map { |row| row[:compactions]&.first }
                          .select { |c| c[:tokens_before] && c[:tokens_after] }
      return "-" if firsts.empty?

      before = firsts.sum { |c| c[:tokens_before] }.fdiv(firsts.length).round
      after = firsts.sum { |c| c[:tokens_after] }.fdiv(firsts.length).round
      "#{before} -> #{after}"
    end

    def compaction_cost(row) = Array(row[:compactions]).sum { |item| item[:cost] || 0.0 }

    def total_cost(row)
      compaction_cost(row) + (row[:cost] || 0.0) + (row.dig(:judge, :cost) || 0.0)
    end
  end
end
