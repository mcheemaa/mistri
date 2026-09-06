# frozen_string_literal: true

require "json"

module CompactionEval
  # Rows in, tables out: a progress line per row while a run is going, a
  # markdown report for a results file, and a comparison between two files
  # (a baseline and a candidate prompt, usually).
  module Report
    KEY = %i[model scenario size mode].freeze
    COLUMNS = ["model", "scenario", "size", "mode", "probes", "changed", "deep", "continuation",
               "literal", "summary tok", "before → after", "compaction $", "total $"].freeze
    REGRESSION = 0.05

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
      lines = ["# Compaction eval comparison", "", versions(base, candidate), "",
               table(%w[model scenario size mode probes changed continuation] + ["summary tok"])]
      regressions = []
      grouped(candidate).each do |key, group|
        before = grouped(base)[key]
        next unless before

        delta = delta_for(before, group, :probe_accuracy)
        regressions << key.join(" ") if delta && delta < -REGRESSION
        lines << table([*key, signed(delta), signed(delta_for(before, group, :changed_accuracy)),
                        signed(delta_for(before, group) { |row| continued(row) }),
                        "#{summary_tokens(before.first)} → #{summary_tokens(group.first)}"])
      end
      [*lines, "", verdict(regressions)].join("\n")
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
       pct(mean(group) { |row| row.dig(:accuracy_by_carrier, :tool_deep) }),
       pct(mean(group) { |row| continued(row) }), pct(mean(group, :literal_recall)),
       summary_tokens(first), compression(first),
       money(mean(group) { |row| compaction_cost(row) }),
       money(mean(group) { |row| total_cost(row) })]
    end

    def misses(rows)
      failed = rows.reject { |row| row[:skipped] || row[:mode] != "compacted" }.flat_map do |row|
        Array(row[:probes]).reject { |probe| probe[:pass] }.map do |probe|
          "- #{row[:model]} #{row[:scenario]} #{row[:size]}: #{probe[:key]} (#{probe[:carrier]}) " \
            "expected #{Array(probe[:answer]).first.inspect}, " \
            "got #{probe[:reply].to_s[0, 80].inspect}"
        end
      end
      failed.empty? ? ["All probes passed."] : ["## Missed probes", "", *failed]
    end

    def verdict(regressions)
      points = (REGRESSION * 100).round
      return "No probe-accuracy regression beyond #{points} points." if regressions.empty?

      "Probe-accuracy regressions beyond #{points} points: #{regressions.join("; ")}."
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

    def signed(delta) = delta.nil? ? "–" : format("%<pts>+d pts", pts: (delta * 100).round)

    def money(value) = value.nil? ? "–" : format("$%<usd>.3f", usd: value)

    def summary_tokens(row) = row[:compactions]&.last&.dig(:summary_tokens) || "–"

    def compression(row)
      last = row[:compactions]&.last
      last ? "#{last[:tokens_before]} → #{last[:tokens_after]}" : "–"
    end

    def compaction_cost(row) = Array(row[:compactions]).sum { |item| item[:cost] || 0.0 }

    def total_cost(row) = compaction_cost(row) + (row[:cost] || 0.0)
  end
end
