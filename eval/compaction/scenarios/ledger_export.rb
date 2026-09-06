# frozen_string_literal: true

# A finance-operations session: exact deliverable names, hard rules, numbers
# that must not drift, a decision reversed mid-way, a renamed file, and a
# credential rule. Most of the bulk is worker-log noise, as in real sessions.
CompactionEval::Scenario.define("ledger_export",
                                summary: "Q3 ledger export with a rename mid-way") do
  filler do |turn, rng|
    shard = turn % 8
    {
      ask: "Continue with step #{turn + 1}: check shard #{shard} of the export job and report " \
           "what the log says about retries and latency.",
      doing: "Checking shard #{shard} of the export worker log for step #{turn + 1}; looking " \
             "for retries, skipped jobs and the p95 latency before deciding on the batch size.",
      tool: "run_command",
      arguments: { "command" => "tail -n 40 log/export_worker_#{shard}.log" },
      log: lambda { |chars|
        CompactionEval::Noise.lines(rng, chars) do |index, random|
          format("%<at>s worker-%<worker>d job=%<job>d status=%<status>s latency=%<ms>dms " \
                 "shard=%<shard>d",
                 at: CompactionEval::Noise.stamp(random), worker: random.rand(12),
                 job: 400_000 + random.rand(90_000),
                 status: %w[ok ok ok ok retry skipped][random.rand(6)],
                 ms: 20 + random.rand(900), shard: index % 8)
        end
      },
      done: "Shard #{shard} looks healthy for step #{turn + 1}: retries are within the normal " \
            "band and latency is stable, so no batch size change is needed yet."
    }
  end

  segment do
    fact :ticket, "SEND-2831",
         at: 0.0,
         text: "We are shipping the Q3 ledger export for ticket %<value>s.",
         probe: "Which ticket id is this work for? Reply with the id only."
    fact :filename, "exports/q3_ledger_2026-09-05_v7.csv",
         at: 0.0,
         text: "The output file must be named exactly %<value>s.",
         probe: "What exact filename must the export use now? Reply with the path only."
    fact :footer, "Prepared by Ada Lovelace for Finance (do not distribute)",
         at: 0.0,
         text: "The last line of the file must be the footer \"%<value>s\".",
         probe: "What exact footer line must end the file? Reply with the line only."
    fact :no_where, "no",
         at: 0.02, match: :yes_no,
         text: "Hard rule: never run an UPDATE without a WHERE clause.",
         probe: "May you run an UPDATE statement without a WHERE clause? Answer yes or no."
    fact :no_table, "payments_ledger",
         at: 0.02,
         text: "Do not touch the %<value>s table at all; Finance owns it.",
         probe: "Which table must you not touch? Reply with the table name only."
    fact :mr, "https://gitlab.com/sendoso/sendoso/-/merge_requests/34977",
         at: 0.05,
         text: "The merge request to extend is %<value>s.",
         probe: "Which merge request are we extending? Reply with the URL only."
    fact :decimals, "two",
         at: 0.08, answer: %w[two 2],
         text: "Amounts are in USD with %<value>s decimal places.",
         probe: "How many decimal places do amounts use? Reply with the number only."
    fact :slack, "#q3-close",
         at: 0.12,
         text: "Before running anything against production, post in Slack %<value>s and wait " \
               "for a thumbs up.",
         probe: "Which Slack channel must be told before a production run? Reply with the " \
                "channel only."
    fact :shards, "8",
         at: 0.15, carrier: :assistant,
         text: "The export job is split across %<value>s shards, one worker log each.",
         probe: "How many export shards are there? Reply with the number only."
    fact :dedupe, "argMax",
         at: 0.2,
         text: "For the dedupe query use ClickHouse %<value>s for now.",
         probe: "Which ClickHouse construct do we use for dedupe now? Reply with the keyword only."
    fact :amount, "$3,948,820.57",
         at: 0.3,
         text: "The reversal amount we are reconciling is %<value>s; keep that exact figure in " \
               "the export header.",
         probe: "What exact reversal amount goes in the export header? Reply with the amount only."
    fact :port, "5433",
         at: 0.32,
         text: "The read replica listens on port %<value>s, not 5432.",
         probe: "Which port does the read replica listen on? Reply with the number only."
    fact :p95, "900",
         at: 0.35, carrier: :assistant,
         text: "I will treat a shard as unhealthy when its p95 latency is above %<value>sms.",
         probe: "Above what p95 latency in milliseconds is a shard unhealthy? Reply with the " \
                "number only."
    fact :cutoff, "Friday 17:00 PT",
         at: 0.4,
         text: "Finance needs the file before %<value>s.",
         probe: "What is the delivery cutoff now? Reply with the day and time only."
    fact :error, 'PG::UndefinedColumn: column "team_group_id" does not exist',
         at: 0.5,
         carrier: :tool, answer: 'column "team_group_id" does not exist',
         text: "ERROR %<value>s\n  from app/services/ledger_export/rows.rb:41",
         probe: "What exact database error did the export worker log? Quote the error message."
    fact :error_site, "app/services/ledger_export/rows.rb:41",
         at: 0.5, carrier: :assistant,
         text: "The failure comes from %<value>s: the column moved when teams became team " \
               "groups, so the rows query needs the join through team_groups first.",
         probe: "Which file and line raised the export error? Reply with file:line only."
    change :dedupe, "FINAL",
           at: 0.6, answer: "double count",
           text: "Decision: switch the dedupe query to ClickHouse %<value>s instead of argMax; " \
                 "argMax was double counting refunds.",
           probe: "Why was argMax rejected for dedupe? Answer briefly."
    fact :retry_job, "439597",
         at: 0.65, carrier: :tool_deep,
         text: "job=%<value>s status=retry latency=905ms shard=5 note=poison-pill",
         probe: "Which job id carried the poison-pill note? Reply with the job id only."
    change :filename, "exports/q3_ledger_2026-09-05_v8.csv",
           at: 0.7, answer: "yes",
           match: :yes_no,
           text: "Rename: the file must now be named %<value>s, not the earlier name.",
           probe: "Was the export filename changed during this work? Answer yes or no."
    fact :vault, "Finance-Prod",
         at: 0.78,
         text: "The export token comes from the 1Password vault %<value>s.",
         probe: "Which 1Password vault holds the export token? Reply with the vault name only."
    fact :token_env, "LEDGER_EXPORT_TOKEN",
         at: 0.8,
         text: "Read the token from the env var %<value>s.",
         probe: "Which environment variable carries the export token? Reply with the name only."
    fact :no_log, "no",
         at: 0.82, match: :yes_no,
         text: "The token must never appear in any log line.",
         probe: "May the export token appear in logs? Answer yes or no."
    fact :owner, "Priya Natarajan",
         at: 0.85,
         text: "%<value>s signs off the file before it goes to Finance.",
         probe: "Who signs off the file before delivery? Reply with the name only."
  end

  segment do
    fact :router_ticket, "AP-2101",
         at: 0.1,
         text: "Infra opened %<value>s for the router; mention it in the handoff.",
         probe: "Which ticket did infra open for the router? Reply with the id only."
    fact :restart, "docker restart apollo-router",
         at: 0.2,
         text: "After every schema change run `%<value>s` before testing.",
         probe: "Which command must run after every schema change? Reply with the command only."
    change :cutoff, "Thursday 15:00 PT",
           at: 0.5,
           text: "Finance moved the cutoff to %<value>s."
    fact :rows, "184,203",
         at: 0.7, carrier: :tool,
         text: "export dry run: %<value>s rows written, 0 rejected",
         probe: "How many rows did the dry run write? Reply with the number only."
  end

  continuation prompt: "Finance approved. Save the export now with the agreed filename, footer, " \
                       "header amount, and replica port. Call save_export once with the exact " \
                       "values.",
               tool: "save_export",
               description: "Writes the ledger export with the agreed values.",
               schema: lambda {
                 string :filename, "Exact output path", required: true
                 string :footer, "Exact last line of the file", required: true
                 string :header_amount, "Exact reversal amount for the header", required: true
                 string :replica_port, "Read replica port", required: true
               },
               expected: lambda { |latest|
                 { "filename" => latest[:filename], "footer" => latest[:footer],
                   "header_amount" => latest[:amount], "replica_port" => latest[:port] }
               }
end
