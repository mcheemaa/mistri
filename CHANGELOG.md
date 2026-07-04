# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- Two-channel tool results: a handler may return Mistri::ToolResult with
  content for the model and ui for the host. The ui payload rides the tool
  message and its :tool_result event, persists with the session for
  transcript re-renders, and never reaches a provider.

- Context compaction: sessions compact automatically when the context grows
  into the reserve headroom (compaction: on the Agent, on by default when the
  model's window is known; pass false to disable). The provider writes a
  visible structured summary; a compaction entry redirects replay to summary
  plus kept tail while the full history stays in the store. Cuts land only on
  user messages so tool pairs never split, parked approvals stay resumable,
  and second compactions update the first summary. Agent#compact is the
  manual button, Agent#context_usage the {tokens, window, fraction} gauge,
  and :compacting/:compaction the events.

- transform_context: an Agent option that reshapes what the model sees each
  turn (reminders, redaction, windowing) while the stored transcript stays
  untouched. The lambda receives the replay messages and returns the messages
  to send; it must keep tool calls paired with their results.

- Steering: Session#steer queues a user message from any process while a run
  is live. The loop folds pending steers into the transcript at the next turn
  boundary, and one that arrives as the model finishes cleanly extends the
  run so it gets answered instead of dangling. Steers compose with approval
  suspensions: queue a thought, approve, resume.

- Human-in-the-loop approval: a tool marked needs_approval (true or a
  predicate on its arguments) suspends the run instead of executing. Runs
  return a Result immediately; decisions are recorded on the session from any
  process (approve/deny), and resume settles them and continues. No thread
  ever waits on a human.
- Every run now returns a Mistri::Result (completed, awaiting_approval,
  aborted, budget, or error) that delegates text and stop_reason to its final
  message.
- Session entries are normalized to one canonical JSON shape across all
  stores.

- Budget stops report stop_reason :budget, distinct from a user abort.
- Tool results that are arrays of data serialize as JSON; empty input and
  duplicate tool names fail loudly at the boundary.

- `Mistri::Memory` and `Mistri::Tools.memory`: durable knowledge across
  sessions, read and rewritten whole, living wherever the host points it.

- `Mistri::Workspace`: the document store agents work in, with memory,
  directory, ActiveRecord, and single-document backends, so editing a
  database column works exactly like editing a file.
- `Mistri::Tools.files`: the built-in document tools (read_file, write_file,
  edit_file, find_in_file, list_files). The edit tool speaks the flat
  old_string/new_string shape models are trained on, tolerates alias keys,
  and reports misses with the closest region and its exact difference.
- `Mistri::Edit.replace`: single-edit replacement with replace_all, newline
  and BOM preservation, and near-miss diagnostics.

- Truncated streams now fail as retryable errors on every provider instead of
  reading as user cancellations, and their tool calls pair without executing.
- Provider error turns carry the HTTP status and response body.
- Budgets measure every ceiling per run, including wall clock.

- `Mistri::Edit`: pure fuzzy text replacement with a uniqueness guarantee,
  so an edit never silently changes the wrong region; the string core for a
  workspace-backed edit tool that works against a database as well as a file.

- `Mistri.agent` and `Mistri.provider`: build an agent or provider from a model
  id, inferring the provider and reading its key from the environment.

- Aborted and truncated turns now replay without provider errors: unusable
  thinking degrades to text, empty blocks are dropped, every tool call is
  paired, and budget-only models skip adaptive thinking.

- The error hierarchy: every Mistri failure rescues as `Mistri::Error`.
- The message protocol: immutable content blocks (text, thinking, image, tool call),
  messages with provider identity, usage accounting with cost math, stop reasons.
- The streaming event union: twelve event types, each carrying an immutable
  partial-message snapshot.
- `Mistri::Providers::Fake`: a scriptable provider for hermetic host tests.
- `Mistri::AbortSignal`: a thread-safe cancel latch with abort callbacks.
- `Mistri::SSE`: an incremental server-sent-events decoder.
- `Mistri::Transport`: a persistent per-provider streaming connection with
  status-mapped errors and hard abort of hung streams.
- `Mistri::PartialJson`: best-effort parsing of in-flight tool arguments.
- `Mistri::Models`: a capability catalog with graceful passthrough, so unknown
  models work the day they ship.
- `Mistri::Providers::Anthropic`: the Messages API streamed, with adaptive
  thinking, prompt caching, signature round-trips, and eager tool-input
  streaming.
- `Mistri::Providers::OpenAI`: the Responses API streamed and stateless, with
  encrypted reasoning replay and thinking summaries.
- `Mistri::Providers::Gemini`: generateContent streamed, with unconstrained
  thinking by default and verbatim thought-signature replay.
- `Mistri::Agent`: the streaming tool-calling loop, persisting each turn as it
  completes so aborts and crashes resume without repair.
- `Mistri::Tool` and `Mistri::Schema`: define tools with a raw JSON Schema or a
  Ruby schema block; results may be text, JSON, or content blocks.
- `Mistri::Session` with pluggable stores (`Memory`, `JSONL`, and an optional
  `ActiveRecord` adapter for the host's own database).
- `Mistri::Budget`: opt-in ceilings on turns, tokens, cost, and wall-clock;
  nothing is enforced unless the host sets it.

## [0.0.3] - 2026-07-04

- Repository moved to github.com/mcheemaa/mistri.
- Development toolchain: Minitest, RuboCop, CI.

## [0.0.1] - 2026-07-04

- Reserved the gem name.
