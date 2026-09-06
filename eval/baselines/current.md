# Compaction eval

54 rows, git 6ed9d01, prompt 558eb0bcb2d4, grader 2026-09-06.2, total $36.104

| model | scenario | size | mode | probes | changed | deep | continuation | literal | unsupported | resumability | summary tok | before -> after | compaction $ | total $ |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| claude-sonnet-5 | account_research | S | compacted | 94% | 100% | 0% | 100% | 94% | 10.0 | 4.0 | 1066 | 6289 -> 2398 | $0.123 | $0.625 |
| claude-sonnet-5 | account_research | S | full | 100% | 100% | 100% | 100% | - | - | - | - | - | $0.000 | $0.792 |
| claude-sonnet-5 | account_research | S | tail | 31% | 0% | 100% | 0% | - | - | - | - | - | $0.000 | $0.233 |
| claude-sonnet-5 | incident_debugging | S | compacted | 86% | 100% | 0% | 100% | 92% | 5.0 | 4.0 | 1651 | 6298 -> 2479 | $0.146 | $0.721 |
| claude-sonnet-5 | incident_debugging | S | full | 100% | 100% | 100% | 100% | - | - | - | - | - | $0.000 | $0.843 |
| claude-sonnet-5 | incident_debugging | S | tail | 13% | 0% | 0% | 0% | - | - | - | - | - | $0.000 | $0.259 |
| claude-sonnet-5 | ledger_export | S | compacted | 92% | 90% | 0% | 100% | 90% | 8.5 | 3.5 | 1848 | 6598 -> 2144 | $0.159 | $0.983 |
| claude-sonnet-5 | ledger_export | S | full | 100% | 100% | 100% | 100% | - | - | - | - | - | $0.000 | $1.315 |
| claude-sonnet-5 | ledger_export | S | tail | 13% | 0% | 0% | 0% | - | - | - | - | - | $0.000 | $0.246 |
| claude-sonnet-5 | account_research | M | compacted | 94% | 100% | 0% | 100% | 94% | 7.0 | 4.0 | 1260 | 26399 -> 2511 | $0.272 | $1.137 |
| claude-sonnet-5 | incident_debugging | M | compacted | 89% | 100% | 0% | 50% | 89% | 9.0 | 4.0 | 1656 | 26390 -> 2883 | $0.305 | $1.323 |
| claude-sonnet-5 | ledger_export | M | compacted | 92% | 100% | 0% | 100% | 92% | 10.0 | 4.0 | 2171 | 27500 -> 2504 | $0.348 | $1.689 |
| gpt-5.6-sol | account_research | S | compacted | 94% | 100% | 0% | 100% | 94% | 2.5 | 4.5 | 925 | 6289 -> 2237 | $0.103 | $0.584 |
| gpt-5.6-sol | account_research | S | full | 100% | 100% | 100% | 100% | - | - | - | - | - | $0.000 | $0.078 |
| gpt-5.6-sol | account_research | S | tail | 38% | 0% | 100% | 0% | - | - | - | - | - | $0.000 | $0.292 |
| gpt-5.6-sol | incident_debugging | S | compacted | 86% | 100% | 0% | 50% | 89% | 0.0 | 5.0 | 994 | 6298 -> 2374 | $0.126 | $0.653 |
| gpt-5.6-sol | incident_debugging | S | full | 94% | 0% | 100% | 100% | - | - | - | - | - | $0.000 | $0.101 |
| gpt-5.6-sol | incident_debugging | S | tail | 19% | 0% | 0% | 0% | - | - | - | - | - | $0.000 | $0.291 |
| gpt-5.6-sol | ledger_export | S | compacted | 96% | 100% | 0% | 100% | 92% | 2.0 | 4.5 | 1186 | 6598 -> 2005 | $0.150 | $0.964 |
| gpt-5.6-sol | ledger_export | S | full | 96% | 100% | 100% | 100% | - | - | - | - | - | $0.000 | $0.154 |
| gpt-5.6-sol | ledger_export | S | tail | 22% | 25% | 0% | 0% | - | - | - | - | - | $0.000 | $0.303 |
| gpt-5.6-sol | account_research | M | compacted | 94% | 100% | 0% | 100% | 94% | 3.5 | 4.0 | 920 | 26399 -> 2381 | $0.291 | $1.139 |
| gpt-5.6-sol | incident_debugging | M | compacted | 75% | 50% | 0% | 0% | 81% | 0.0 | 5.0 | 1175 | 26390 -> 2471 | $0.346 | $1.300 |
| gpt-5.6-sol | ledger_export | M | compacted | 96% | 100% | 0% | 100% | 92% | 2.5 | 4.0 | 1327 | 27500 -> 2101 | $0.424 | $1.681 |
| gemini-2.5-flash | account_research | S | compacted | 86% | 100% | 0% | 50% | 86% | 3.0 | 3.0 | 615 | 6289 -> 2101 | $0.013 | $0.220 |
| gemini-2.5-flash | account_research | S | full | 100% | 100% | 100% | 100% | - | - | - | - | - | $0.000 | $0.025 |
| gemini-2.5-flash | account_research | S | tail | 25% | 0% | 0% | 0% | - | - | - | - | - | $0.000 | $0.015 |
| gemini-2.5-flash | incident_debugging | S | compacted | 72% | 75% | 0% | 50% | 78% | 3.5 | 3.0 | 760 | 6298 -> 2117 | $0.017 | $0.250 |
| gemini-2.5-flash | incident_debugging | S | full | 100% | 100% | 100% | 100% | - | - | - | - | - | $0.000 | $0.042 |
| gemini-2.5-flash | incident_debugging | S | tail | 13% | 0% | 0% | 0% | - | - | - | - | - | $0.000 | $0.025 |
| gemini-2.5-flash | ledger_export | S | compacted | 90% | 100% | 0% | 100% | 87% | 2.0 | 3.5 | 1257 | 6598 -> 1933 | $0.024 | $0.295 |
| gemini-2.5-flash | ledger_export | S | full | 100% | 100% | 100% | 100% | - | - | - | - | - | $0.000 | $0.057 |
| gemini-2.5-flash | ledger_export | S | tail | 13% | 0% | 0% | 0% | - | - | - | - | - | $0.000 | $0.029 |
| gemini-2.5-flash | account_research | M | compacted | 83% | 100% | 0% | 0% | 83% | 0.5 | 3.5 | 615 | 26399 -> 2177 | $0.024 | $0.525 |
| gemini-2.5-flash | incident_debugging | M | compacted | 75% | 100% | 0% | 100% | 83% | 1.5 | 4.0 | 930 | 26390 -> 2353 | $0.033 | $0.617 |
| gemini-2.5-flash | ledger_export | M | compacted | 89% | 90% | 0% | 100% | 89% | 3.5 | 3.0 | 2096 | 27500 -> 2684 | $0.061 | $0.795 |

## Misses

- claude-sonnet-5 account_research S: hobby (tool_deep) expected nil, got ""
- claude-sonnet-5 account_research S: hobby (tool_deep) expected nil, got ""
- claude-sonnet-5 incident_debugging S: request_id (tool_deep) expected nil, got ""
- claude-sonnet-5 incident_debugging S: next_step (assistant) expected nil, got ""
- claude-sonnet-5 incident_debugging S: timeout_env (tool) expected nil, got ""
- claude-sonnet-5 incident_debugging S: request_id (tool_deep) expected nil, got ""
- claude-sonnet-5 incident_debugging S: next_step (assistant) expected nil, got ""
- claude-sonnet-5 ledger_export S: retry_job (tool_deep) expected nil, got ""
- claude-sonnet-5 ledger_export S: retry_job (tool_deep) expected nil, got ""
- claude-sonnet-5 ledger_export S: rows (tool) expected nil, got ""
- claude-sonnet-5 ledger_export S: filename_v2 (user) expected nil, got ""
- claude-sonnet-5 account_research M: hobby (tool_deep) expected nil, got ""
- claude-sonnet-5 account_research M: hobby (tool_deep) expected nil, got ""
- claude-sonnet-5 incident_debugging M: timeout_env (tool) expected nil, got ""
- claude-sonnet-5 incident_debugging M: request_id (tool_deep) expected nil, got ""
- claude-sonnet-5 incident_debugging M: failing_spec (tool) expected nil, got ""
- claude-sonnet-5 incident_debugging M: request_id (tool_deep) expected nil, got ""
- claude-sonnet-5 incident_debugging M: continuation wrong error_rate
- claude-sonnet-5 ledger_export M: shards (assistant) expected nil, got ""
- claude-sonnet-5 ledger_export M: retry_job (tool_deep) expected nil, got ""
- claude-sonnet-5 ledger_export M: shards (assistant) expected nil, got ""
- claude-sonnet-5 ledger_export M: retry_job (tool_deep) expected nil, got ""
- gpt-5.6-sol account_research S: hobby (tool_deep) expected nil, got ""
- gpt-5.6-sol account_research S: hobby (tool_deep) expected nil, got ""
- gpt-5.6-sol incident_debugging S: timeout_env (tool) expected nil, got ""
- gpt-5.6-sol incident_debugging S: request_id (tool_deep) expected nil, got ""
- gpt-5.6-sol incident_debugging S: timeout_env (tool) expected nil, got ""
- gpt-5.6-sol incident_debugging S: request_id (tool_deep) expected nil, got ""
- gpt-5.6-sol incident_debugging S: revert_pr (tool) expected nil, got ""
- gpt-5.6-sol incident_debugging S: continuation wrong root_cause
- gpt-5.6-sol ledger_export S: retry_job (tool_deep) expected nil, got ""
- gpt-5.6-sol ledger_export S: retry_job (tool_deep) expected nil, got ""
- gpt-5.6-sol account_research M: hobby (tool_deep) expected nil, got ""
- gpt-5.6-sol account_research M: hobby (tool_deep) expected nil, got ""
- gpt-5.6-sol incident_debugging M: error_rate (assistant) expected nil, got ""
- gpt-5.6-sol incident_debugging M: timeout_env (tool) expected nil, got ""
- gpt-5.6-sol incident_debugging M: request_id (tool_deep) expected nil, got ""
- gpt-5.6-sol incident_debugging M: revert_pr (tool) expected nil, got ""
- gpt-5.6-sol incident_debugging M: continuation wrong error_rate, root_cause
- gpt-5.6-sol incident_debugging M: error_rate (assistant) expected nil, got ""
- gpt-5.6-sol incident_debugging M: failing_spec (tool) expected nil, got ""
- gpt-5.6-sol incident_debugging M: timeout_env (tool) expected nil, got ""
- gpt-5.6-sol incident_debugging M: request_id (tool_deep) expected nil, got ""
- gpt-5.6-sol incident_debugging M: revert_pr (tool) expected nil, got ""
- gpt-5.6-sol incident_debugging M: continuation wrong error_rate
- gpt-5.6-sol ledger_export M: retry_job (tool_deep) expected nil, got ""
- gpt-5.6-sol ledger_export M: retry_job (tool_deep) expected nil, got ""
- gemini-2.5-flash account_research S: hobby (tool_deep) expected nil, got ""
- gemini-2.5-flash account_research S: second_contact (tool) expected nil, got ""
- gemini-2.5-flash account_research S: email (tool) expected nil, got ""
- gemini-2.5-flash account_research S: hobby (tool_deep) expected nil, got ""
- gemini-2.5-flash account_research S: second_contact (tool) expected nil, got ""
- gemini-2.5-flash account_research S: continuation no tool call
- gemini-2.5-flash incident_debugging S: error (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging S: failing_spec (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging S: timeout_env (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging S: request_id (tool_deep) expected nil, got ""
- gemini-2.5-flash incident_debugging S: revert_pr (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging S: error_rate (assistant) expected nil, got ""
- gemini-2.5-flash incident_debugging S: failing_spec (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging S: timeout_env (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging S: request_id (tool_deep) expected nil, got ""
- gemini-2.5-flash incident_debugging S: revert_pr (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging S: continuation wrong error_rate
- gemini-2.5-flash ledger_export S: p95 (assistant) expected nil, got ""
- gemini-2.5-flash ledger_export S: retry_job (tool_deep) expected nil, got ""
- gemini-2.5-flash ledger_export S: rows (tool) expected nil, got ""
- gemini-2.5-flash ledger_export S: retry_job (tool_deep) expected nil, got ""
- gemini-2.5-flash ledger_export S: rows (tool) expected nil, got ""
- gemini-2.5-flash account_research M: email (tool) expected nil, got ""
- gemini-2.5-flash account_research M: hobby (tool_deep) expected nil, got ""
- gemini-2.5-flash account_research M: continuation no tool call
- gemini-2.5-flash account_research M: email (tool) expected nil, got ""
- gemini-2.5-flash account_research M: address (tool) expected nil, got ""
- gemini-2.5-flash account_research M: opportunity (tool) expected nil, got ""
- gemini-2.5-flash account_research M: hobby (tool_deep) expected nil, got ""
- gemini-2.5-flash account_research M: continuation wrong email
- gemini-2.5-flash incident_debugging M: error (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging M: failing_spec (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging M: timeout_env (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging M: request_id (tool_deep) expected nil, got ""
- gemini-2.5-flash incident_debugging M: revert_pr (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging M: failing_spec (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging M: timeout_env (tool) expected nil, got ""
- gemini-2.5-flash incident_debugging M: request_id (tool_deep) expected nil, got ""
- gemini-2.5-flash incident_debugging M: revert_pr (tool) expected nil, got ""
- gemini-2.5-flash ledger_export M: error (tool) expected nil, got ""
- gemini-2.5-flash ledger_export M: retry_job (tool_deep) expected nil, got ""
- gemini-2.5-flash ledger_export M: rows (tool) expected nil, got ""
- gemini-2.5-flash ledger_export M: retry_job (tool_deep) expected nil, got ""
- gemini-2.5-flash ledger_export M: rows (tool) expected nil, got ""
- gemini-2.5-flash ledger_export M: filename_v2 (user) expected nil, got ""