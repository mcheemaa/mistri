# frozen_string_literal: true

require "json"

module CompactionEval
  # Rows in, tables out: a progress line per row while a run is going, a
  # markdown report for a results file, and a comparison between two files
  # (a baseline and a candidate prompt, usually).
  module Report
    KEY = %i[model scenario size mode].freeze
    COLUMNS = ["model", "scenario", "size", "mode", "probes", "changed", "deep", "continuation",
               "literal", "unsupported", "resumability", "summary tok", "before → after",
               "compaction $", "total $"].freeze
    # Two runs of the same prompt differ by up to six points in one cell and
    # by under two points in a model's aggregate over all cells, so the
    # verdict reads the aggregate and the cell table stays informational.
    REGRESSION = 0.03

    module_function

    def line(row)
      head = format("%<model>-22s %<scenario>-20s %<size>s %<mode>-9s", row)
      return "#{head} skipped: #{row[:skipped]}" if row[:skipped]

      "#{head} probes #{pct(row[:probe_accuracy])}  changed #{pct(row[:changed_accuracy])}  " \
        "continuation #{row.dig(:continuation, :success) ? "ok" : "MISS"}  " \
        "summary #{summary_tokens(row)} tok  #{money(total_cost(row))}"
    end

    def write(rows, path)
      File.open(path, "w") { |file| rows.each { |row| file.puts(JSON.generate(row)) } }
    end

    def read(path)
      File.readlines(path, chomp: true).reject(&:empty?)
          .map { |line| JSON.parse(line, symbolize_names: true) }
    end

    def markdown(rows)
      lines = ["# Compaction eval", "", header(rows), "", table(COLUMNS)]
      grouped(rows).each_value { |group| lines << table(cells(group)) }
      [*lines, "", *misses(rows)].join("\n")
    end

    def compare(base, candidate)
      changed = changed_scenarios(base, candidate)
      base = base.reject { |row| changed.include?(row[:scenario].to_s) }
      candidate = candidate.reject { |row| changed.include?(row[:scenario].to_s) }
      regressions = []
      per_model = aggregates(candidate).filter_map do |model, after|
        before = aggregates(base)[model]
        next unless before

        delta = after[:probes] - before[:probes]
        regressions << model if delta < -REGRESSION
        table([model, "#{pct(before[:probes])} → #{pct(after[:probes])} (#{signed(delta)})",
               "#{pct(before[:changed])} → #{pct(after[:changed])}",
               "#{pct(before[:continuation])} → #{pct(after[:continuation])}",
               "#{number(before[:unsupported])} → #{number(after[:unsupported])}",
               "#{number(before[:resumability])} → #{number(after[:resumability])}"])
      end
      ["# Compaction eval comparison", "", versions(base, candidate), *changed_note(changed), "",
       "## Per model, compacted rows", "",
       table(%w[model probes changed continuation unsupported resumability]),
       *per_model, "", "## Per cell", "", *per_cell(base, candidate), "",
       verdict(regressions)].join("\n")
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

    def changed_note(changed)
      return [] if changed.empty?

      ["", "Scenarios changed since the baseline and left out of this comparison: " \
           "#{changed.join(", ")}. Rerun the baseline to compare them."]
    end

    def per_cell(base, candidate)
      rows = grouped(candidate).filter_map do |key, group|
        before = grouped(base)[key]
        next unless before

        table([*key, signed(delta_for(before, group, :probe_accuracy)),
               signed(delta_for(before, group, :changed_accuracy)),
               signed(delta_for(before, group) { |row| continued(row) }),
               "#{summary_tokens(before.first)} → #{summary_tokens(group.first)}"])
      end
      [table(%w[model scenario size mode probes changed continuation] + ["summary tok"]), *rows]
    end

    # One number per model across every compacted cell, weighted by probes,
    # so a model with more scenarios does not count more per scenario.
    def aggregates(rows)
      compacted = rows.reject { |row| row[:skipped] || row[:mode] != "compacted" }
      compacted.group_by { |row| row[:model].to_s }.to_h do |model, group|
        probes = group.flat_map { |row| Array(row[:probes]) }
        changed = probes.select { |probe| probe[:changed] }
        [model, { probes: ratio(probes), changed: ratio(changed),
                  continuation: group.count { |row| row.dig(:continuation, :success) }
                                     .fdiv(group.length),
                  unsupported: mean(group) { |row| row.dig(:judge, :unsupported) },
                  resumability: mean(group) { |row| row.dig(:judge, :resumability) } }]
      end
    end

    def ratio(probes)
      probes.empty? ? 0.0 : probes.count { |probe| probe[:pass] }.fdiv(probes.length)
    end

    def grouped(rows)
      rows.reject { |row| row[:skipped] }.group_by { |row| KEY.map { |key| row[key].to_s } }
    end

    def header(rows)
      "#{rows.length} rows, git #{rows.map { |row| row[:git_sha] }.uniq.join("/")}, prompt " \
        "#{rows.map { |row| row[:prompt_digest] }.uniq.join("/")}, " \
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
       summary_tokens(first), compression(first),
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

    def continuation_miss(row)
      continuation = row[:continuation]
      return [] if continuation.nil? || continuation[:success]

      wrong = continuation[:expected].keys.map(&:to_s) - continuation[:matched].map(&:to_s)
      detail = continuation[:called] ? "wrong #{wrong.join(", ")}" : continuation[:status].to_s
      ["- #{row[:model]} #{row[:scenario]} #{row[:size]}: continuation #{detail}"]
    end

    def verdict(regressions)
      points = (REGRESSION * 100).round
      if regressions.empty?
        return "No model loses more than #{points} points of aggregate probe accuracy."
      end

      "Aggregate probe accuracy drops more than #{points} points: #{regressions.join(", ")}."
    end

    def mean(group, key = nil, &)
      values = group.map { |row| key ? row[key] : yield(row) }.compact
      values.empty? ? nil : values.sum / values.length
    end

    def delta_for(before, after, key = nil, &)
      earlier = key ? mean(before, key) : mean(before, &)
      later = key ? mean(after, key) : mean(after, &)
      earlier && later ? (later - earlier).round(3) : nil
    end

    def continued(row) = row.dig(:continuation, :success) ? 1.0 : 0.0

    def pct(value) = value.nil? ? "–" : "#{(value * 100).round}%"

    def number(value) = value.nil? ? "–" : format("%<n>.1f", n: value)

    def signed(delta) = delta.nil? ? "–" : format("%<pts>+d pts", pts: (delta * 100).round)

    def money(value) = value.nil? ? "–" : format("$%<usd>.3f", usd: value)

    def summary_tokens(row) = row[:compactions]&.last&.dig(:summary_tokens) || "–"

    # The main compaction's numbers: a fold compacts a checkpoint plus a few
    # turns, which says little about the size the summary had to cover.
    def compression(row)
      first = row[:compactions]&.first
      first ? "#{first[:tokens_before]} → #{first[:tokens_after]}" : "–"
    end

    def compaction_cost(row) = Array(row[:compactions]).sum { |item| item[:cost] || 0.0 }

    def total_cost(row) = compaction_cost(row) + (row[:cost] || 0.0)
  end
end
