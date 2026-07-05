# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] - 2026-07-05

- Sessions heal at replay: a run killed mid-tool (deploy, crash) leaves
  tool calls without results, which providers reject on every later turn.
  Unsettled calls now replay with a synthesized interrupted result; calls
  parked for human approval stay open for resume. The stored log is never
  rewritten, and context assembly now reads the store exactly once.
- Empty completions retry: a turn that answers with no text, thinking, or
  tool calls (an intermittent provider behavior) now retries under the
  standard policy instead of ending the run in silence.
- Gemini: consecutive user turns are no longer merged. Mixing a text part
  into a functionResponse turn makes Gemini answer an empty candidate, so
  steers and resumed prompts stay their own turns; Gemini accepts this.
- The spawn tool takes an optional `name`: the model labels each worker,
  and the label rides origin tags and the transcript link, so fan-out
  streams read as `pricing-scout#a41f` instead of `spawn#a41f`.
- The spawn tool's `model` parameter names the default child model in its
  description, so the model's choice (or non-choice) is informed.

## [0.2.1] - 2026-07-05

- The gem homepage and documentation links now point at
  [mistri.sh](https://mistri.sh), the project site with full docs at
  [mistri.sh/docs](https://mistri.sh/docs/getting-started/).
- README polish: wordmark, testing section.

## [0.2.0] - 2026-07-05

- Repository hygiene: coverage floor enforced in CI (simplecov, 90% line),
  contributing/security/conduct docs, issue and PR templates, Dependabot,
  and rubygems documentation and bug tracker links.

- Per-tool timeouts: Tool.define(..., timeout: 30) answers in band when a
  handler stalls, so one hung tool cannot stall the run.
- :tool_result events carry duration (seconds) for executed tools, feeding
  latency metrics straight from any sink.

- Mistri::Reminder.every(3, text): a periodic tail reminder for long runs,
  riding transform_context; due by completed assistant turns, fresh on the
  wire each time, never persisted.

- Tool hooks: before_tool(call, context) blocks a call by returning the
  reason as a String, answered to the model in band; it outranks the
  approval gate and screens approved calls again at settle time, so an
  aged approval never beats current policy. after_tool(call, result,
  context) may replace a result (both channels), nil keeps it. Hooks that
  raise fail safe: before blocks, after answers in band.
- transform_context accepts an array of transforms, applied in order.

- Result#usage: every run reports its own token and cost accounting,
  summing persisted turns and compaction calls; task sums across its fix
  passes. Hosts meter a run without walking the session.

- MCP stdio wire: Client.new(command: [...], env: {...}) spawns a local
  server as a child process speaking line-delimited JSON-RPC, credentials
  in its environment per spec. Dying servers and non-protocol stdout fail
  loudly; close terminates the child.

- MCP connections out of the box: Mistri::MCP::OAuth.start/.complete/
  .refresh are storage-agnostic services implementing the spec's OAuth 2.1
  subset (challenge and well-known discovery, RFC 8414 metadata with an
  OpenID fallback, dynamic client registration as the host application,
  PKCE with resource indicators, rotating refresh). `rails generate
  mistri:mcp YourModel` creates a host-named connection model whose rows
  carry their own flow state and encrypted tokens, with connection.tools
  bridging straight into an agent and refreshing ahead of expiry.

- MCP bridge: Mistri::MCP::Client speaks Streamable HTTP (initialize
  handshake, tools/list with pagination, tools/call, sessions with
  transparent expiry recovery, JSON or SSE responses) with zero new
  dependencies. Auth is a headers hash or a token string-or-lambda; a
  lambda re-resolves once on 401, so host refresh logic lives in one place.
  Mistri::MCP.tools bridges any server (or any duck-typed client, the
  official mcp gem included) into Mistri tools with allow/deny lists, name
  prefixing, and per-tool approval gates, so a third-party write tool can
  ride the human-approval arc.

## [0.1.0] - 2026-07-05

- Live integration harness: `rake integration` runs every feature end to
  end against real provider APIs, once per model in the matrix
  (MISTRI_INTEGRATION_MODELS overrides the default trio). Scenarios assert
  that generated codenames flowed through the machinery, so answers prove
  information flow rather than model knowledge. The default `rake test`
  stays hermetic.
- The spawn tool's child models now come only from a host allowlist
  (`models:` on SubAgent.spawner); without one no model choice is offered,
  so a hallucinated model id can never construct a provider. Found by the
  integration harness on its first run.
- The skills system-prompt section instructs selection more firmly.

- Sub-agents: delegation with a clean context (#2). Mistri::SubAgent names
  a curated specialist (own provider/system/tools, optional schema: for
  validated JSON answers); SubAgent.spawner is the open spawn_agent tool
  where the model writes the child's instructions, grants a tool subset,
  and may pick a model. Children run fresh sessions on the caller's store,
  linked in its transcript and on the tool result's ui channel; their
  events stream into the parent tagged with origin. Parallel spawn calls
  fan out on the executor pool. Approval-gated tools are refused inside
  children; gate the delegation itself instead.
- Tool handlers now receive an optional second argument, ToolContext
  (session, signal, emit); procs ignore it invisibly and strict lambdas
  keep their old arity. Events gained an origin field.

- Task mode: Agent#task(input, schema:) runs an exchange that must end in
  JSON matching the schema — tools run as usual, providers constrain the
  final answer natively where supported (Anthropic output_config, OpenAI
  text.format strict, Gemini responseJsonSchema when no tools), and the
  answer validates client-side everywhere. A violation goes back to the
  model once (fixes:), then raises SchemaError; Result#output carries the
  validated value. run(output_schema:) exposes raw constrained runs.
- Schema.violations (a zero-dependency validator for the supported subset,
  with model-feedable error messages) and Schema.strict (wire preparation:
  additionalProperties false everywhere, all-required for OpenAI strict).

- Skills: Mistri::Skill and Skills.load (a directory of SKILL.md folders or
  flat .md files, flat-frontmatter name/description). Pass skills: to the
  Agent (array or path): descriptions join the system prompt and a
  read_skill tool serves full bodies on demand, so a skill library costs
  one line each until used. Hosts with skills in a database construct
  Skill objects directly.

- Rails integration: `rails generate mistri:install YourModel` creates a
  host-named entry model and its migration for Stores::ActiveRecord
  (MEDIUMTEXT payload on MySQL-family adapters). Streaming sinks under
  Mistri::Sinks — ActionCable (lazy server, injectable), SSE (outbound
  frames to any IO), and Coalesced (merges delta bursts to UI speed) — all
  pure Ruby, usable as `agent.run(input, &sink)`. No Railtie: generators
  auto-discover and everything else duck-types.

- Retry policy: transient turn failures (429/5xx/529, timeouts, dropped or
  truncated streams) retry with jittered backoff, honoring retry-after. On
  by default (retries: on the Agent; false disables, or pass a tuned
  RetryPolicy). Failed attempts record as retry entries and emit :retry
  events but never become messages, so retries stay invisible to the model.
- Errored messages now carry a machine-readable error field ({type, status,
  retry_after}) alongside error_message; in-stream provider errors keep
  their wire classification (Anthropic overloaded, OpenAI rate limits,
  Gemini status codes) instead of folding into prose.

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

[0.1.0]: https://github.com/mcheemaa/mistri/releases/tag/v0.1.0
