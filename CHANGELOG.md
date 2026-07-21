# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- The ActiveRecord store and workspace read past the host's query cache.
  Rails keeps the cache on for a job's whole span and serves repeated
  identical queries from it, so a parent polling for a child's report inside
  a job never saw the report land and every wait ran to its timeout, and a
  workspace read could serve a stale document. Reads bypass only Rails'
  cache: an open REPEATABLE READ transaction still pins its snapshot, so do
  not poll from inside one.

## [0.6.0] - 2026-07-12

- Synchronous event subscribers now propagate the exact exception object even
  when its class also names an internal failure: provider `Mistri::Error`
  values, transport I/O and timeout errors, SSE `JSON::ParserError`, hook
  failures, and automatic-compaction `CompactionError` can no longer be
  swallowed, retried, folded into an errored assistant turn, or persisted as a
  policy or tool failure. An owner-scoped private marker preserves provenance
  through nested inline agents and unwraps only at the boundary that first
  observed the subscriber. A mid-stream subscriber failure closes the
  interrupted provider connection before propagating. SSE parse tolerance now
  covers `JSON.parse` only, never its callback. Genuine provider, hook, tool,
  and compaction failures keep their existing contracts; configured tool
  timeouts still include progress delivery. Asynchronous background delivery
  remains unable to raise into a caller that has already returned. A callback
  that aborts child execution records the original failure class in its failed
  terminal and dispatcher diagnostic; a post-terminal report callback failure
  leaves the already-durable terminal and parent inbox intact and appears in
  the diagnostic. Active subscribers add one short-lived boundary per provider
  turn, tool batch, hook phase, or automatic compaction and one method/rescue
  frame per delivered event, with no parsing, buffering, I/O, or string work on
  the successful path.
- Approval decisions now behave as a write-once register over the Session
  store's durable order. The first valid decision is authoritative; repeating
  that value is idempotent, while a conflicting caller receives
  `Mistri::ConfigurationError`. Concurrent stale writers may both reach append,
  but every later well-formed decision for that approval request is an inert
  losing occurrence, including one that lands after the approved handler has
  already returned. It cannot revoke the winner, alter settlement, or
  permanently poison `open_approvals`, `resume`, replay, or compaction. The first
  note remains authoritative.
  Malformed decisions, decisions without a matching request, duplicate
  requests, and ambiguous legacy reused-call approvals still fail closed or
  interrupt conservatively. A newly appended decision adds one linear
  control-state re-read to tell a racing loser that it lost; already-visible
  idempotent retries do not append. No provider streaming path changes.
- Anchored `edit_file` changes now compose safely with concurrent writers when
  their Workspace advertises atomic conditional writes. The new optional
  contract is `atomic_writes?`, `snapshot(path)`, and
  `compare_and_write(path, content, expected_revision:)`, with immutable
  `Mistri::Workspace::Snapshot` values and a public
  `Mistri::WorkspaceConflictError`. Memory implements the contract under its
  mutex; the optional Active Record adapter advertises it only for PostgreSQL
  or an InnoDB table on MySQL2 or Trilogy, using exact-byte SHA-256 revisions,
  unique-index create-only CAS, and short transactions without requiring
  `lock_version`. It rejects atomic operations inside a host transaction rather
  than joining a stale or overlong boundary, validates model identity against
  the database catalog, restricts atomic scope to owned scalar equality values,
  and reads the committed row before returning its revision. Single opts in
  through a host `synchronize:` callback that must enforce the same complete
  boundary and outer-transaction rule. Directory, MyISAM, and existing custom
  four-method workspaces retain their documented legacy behavior. `edit_file`
  applies its existing exact/fuzzy anchor outside any lock and retries only a
  lost conditional write, up to three total attempts. An unrelated concurrent
  change is preserved, while a target that no longer matches remains an
  actionable typed edit failure. Callback, validation, I/O, deadlock, and other
  host errors are never retried. Tool names and schemas are unchanged. A
  committed storage transformation produces an explicit
  read-before-continuing failure instead of a false exact-replacement claim.
  Atomic editing adds owned snapshot copies, three exact-byte linear hashes,
  one exact committed-byte comparison, and one conditional commit to the
  ordinary edit path; Memory also returns an owned read copy. Conflicts add at
  most two complete reapplications. Active Record capability adds cached schema
  inspection on the first capability check, outside the edit path. No
  provider streaming path changes. Dedicated MySQL 8.4/InnoDB and PostgreSQL CI
  jobs prove real locking, readback, and unique-create behavior while the gem
  retains zero runtime dependencies.
- Built-in document reads, searches, and edits now return an explicitly failed
  `ToolResult` when the document is missing or a requested replacement cannot
  be applied. The same actionable text still reaches the model, but lifecycle
  events, persisted tool messages, and provider-supported error signaling no
  longer misclassify an expected document-tool failure as success. Tool names,
  schemas, and successful results are unchanged.
- Background dispatch now crosses a versioned, deeply owned JSON capability
  boundary instead of closing over the spawn-time provider, Tool objects, Agent
  options, and workspace state. Every `dispatcher:` requires a host
  `runtime_factory:` that constructs a `SubAgent::Runtime` inside the worker;
  the runtime provider model and unique Tool names must match the durable grant
  exactly before any provider call or tool side effect. Missing, additional,
  renamed, duplicated, non-Tool, reconstructed statically approval-gated, and
  synthetic Skill capabilities fail closed before execution. New immutable
  specs carry `spec_version`, require a model identity, reject unknown fields,
  and omit the model-controlled `workspace` field. The identical canonical
  spec is stored in the child Session before dispatch; `run_dispatched` compares
  the complete queue copy and uses the stored grant for execution and report
  routing, so a changed capability, task, model, name, or parent ID leaves the
  child untouched. Legacy unversioned specs containing `workspace` remain
  executable. Finished redeliveries are rejected before factory construction;
  a configured child lease also rejects concurrent live redeliveries. The
  compatible direct form receives the same grant checks.
  Runtime factory exceptions remain retryable for queues by default; built-in
  in-process runners and an explicit `retry_factory_errors: false` persist a
  terminal failure before re-raising. An optional Runtime `cleanup:` hook runs
  exactly once without masking a primary error. Generic child Agent options
  are allowlisted and travel as one isolated Hash, so they cannot replace the
  durable Session, task, signal, event sink, or other lifecycle state; Runtime
  cannot add Skill capabilities. The dispatched
  lease now spans runtime construction, execution, cleanup, terminal
  persistence, and parent report delivery; it suppresses ordinary stop and
  redelivery races while the tokenless lease remains live. Queued and
  interrupted cancellations now deliver their durable stopped report while holding that
  lease even when the queue never starts or retries the job; repeating stop
  reconciles a transient parent-report failure. A queue copy that does not
  match the persisted grant raises the public, non-retryable
  `Mistri::DispatchGrantError`, which is reserved for grant binding.
  Model selection records only its identity at spawn time; its provider is
  constructed in the worker. `tools: []` now grants no tools, while omission
  keeps the general pool or typed defaults, so an empty typed Definition can no
  longer inherit the entire pool. Duplicate pool, model, or model-selected tool
  names fail before a child starts, and Spawner owns copies of its policy
  arrays. Dispatch adds one bounded spec ownership/comparison and one linear
  capability-name check per child, outside all provider streaming paths.
- Model-originated tool calls now cross a local execution boundary rather than
  relying on provider guidance alone. Completed calls deeply own immutable JSON,
  canonicalize symbol keys without coercing values, retain malformed encoded
  input as a durable `arguments_error`, and stop at 8 MiB, 64 levels, 10,000
  nodes, or a 64 KiB numeric token. The same numeric bound applies to encoded
  JSON and programmatic custom-provider arguments. The Agent requires an object
  argument envelope before `before_tool`, approval predicates, `ends_turn`,
  handlers, or remote MCP calls. Invalid calls receive a bounded typed result in
  band, emit no execution-start event, expose no received field values in core
  errors, and do not prevent valid siblings from running. Results settled in
  the same phase return in model-call order.
  Completed tool-call IDs, names, signatures, and provider correlation IDs must
  be non-empty UTF-8 strings. Live provider turns require IDs unique for the
  session, and provider correlation IDs are unique within one assistant turn.
  Persisted histories recognize only the `call_N` reuse without provider
  correlation IDs that earlier releases synthesized for Gemini and the Fake
  provider, after the prior occurrence was answered or crash-interrupted.
  Replay, provider metadata, and compaction track each occurrence independently
  while live IDs remain reserved for the full session. An unsettled reused-ID
  approval that cannot distinguish its generation becomes an interrupted result
  rather than executable stale authorization. Every other duplicate ID,
  malformed call envelope, or non-assistant provider result rejects the whole
  provider attempt before persistence, policy, or execution. The normal
  provider retry contract retries unchanged history; exhaustion persists a
  pairable error with no tool calls. An abort during normalization, validation,
  policy, or approval evaluation interrupts every uncommitted call and parks no
  approval. Custom
  providers that emitted missing, blank, non-string, non-UTF-8, or duplicate
  identifiers must correct their completed call contract. Each run or resume
  validates every persisted message and audits call identity in one control-state
  preflight before doing work, so malformed legacy history fails closed. The
  preceding assistant entry remains the durable provider source; a normalized
  approval stores the reviewed prepared call plus an explicit provenance
  marker. Resume verifies pairing metadata and revalidates the exact approved
  arguments without rerunning the normalizer. Requests must follow the exact
  assistant call, and decisions must follow one request and carry an exact
  boolean. Duplicate requests and malformed or mismatched controls fail closed.
  The first valid durable decision wins; later well-formed decisions for that
  approval request are inert. Legacy requests remain valid only when they
  exactly mirror the source call.
  Persisted tool results require one prior call with the exact name, settle in
  assistant-call order within each direct or approval phase, and cannot cross
  an unresolved approval; compaction may neither hide an open approval nor
  split a completed call from its result.
  `ToolCall#arguments_error?` is stable; its non-nil string remains an opaque
  diagnostic rather than a public enum. Fake-provider default call IDs now use
  a per-provider UUID namespace plus a monotonic sequence; explicitly scripted
  `id:` values remain deterministic. New approval entries no longer duplicate
  the source argument payload, and generated MySQL-family session tables use
  LONGTEXT so a legal parallel tool turn is not constrained by MEDIUMTEXT's
  16 MiB ceiling. Existing MySQL-family stores must migrate `payload` to
  `size: :long`; generators cannot alter an installed table. `Stores::Memory`
  owns durable appends while returning fresh mutable snapshots, matching stores
  that decode each read.
- Tool schemas compile once into the same deeply frozen canonical UTF-8 JSON
  value used by provider serializers, so mutation and Ruby encoding cannot make
  local validation disagree with the wire. Definition checks cover the complete
  schema document. The zero-dependency runtime subset enforces JSON types and
  unions, `enum`, `required`, `properties`, `prefixItems`, one-schema `items`,
  boolean schemas, and boolean or schema-valued `additionalProperties`.
  `argument_validator:` adds domain rules without weakening core;
  `complete_argument_validator:` is separate explicit authority for every
  argument-applicable non-empty `patternProperties` contract. Tool inputs use
  JSON Schema 2020-12 and require an object root; legacy array-form `items` is
  rejected in favor of `prefixItems`. A schema-less Tool is now a genuinely
  closed no-argument contract; hosts that accepted model fields without
  declaring them must add an explicit schema. The schema-less wire shape
  changed with it, so provider prompt caches re-warm once per affected tool
  set after upgrading. Supplied object schemas preserve
  JSON Schema's default-open semantics unless a raw schema explicitly sets
  `additionalProperties: false`; handlers should extract named fields instead
  of mass-assigning model input. MCP bridging enforces directly reachable
  portable constraints locally and keeps unsupported applicator subtrees and
  other unimplemented standard assertions as guidance for the server, which the
  MCP spec obligates to validate its own tool inputs. A complete validator takes
  explicit whole-contract authority when local policy depends on those
  assertions. External references and
  explicit `inputSchema: null` are rejected in every mode, an omitted schema
  still defaults to a no-argument object, and argument-applicable non-empty
  `patternProperties` still requires complete authority. Common map schemas
  work in core. Task mode rejects assertions local validation cannot guarantee
  before making a provider request, then shares one deeply frozen strict schema
  between its prompt and compiled local validator.
  Providers derive a native constraint only for schema shapes their documented
  and live-verified subsets accept; incompatible shapes fall back to the prompt
  and local correction loop instead of failing the request. Native constraints
  are limited to catalogued matching-provider models and documented provider
  complexity ceilings; unknown models keep the local path. Raw task output is
  byte-bounded, then lexically
  width/depth-bounded before JSON parsing so wide hostile JSON is rejected
  before parser allocation. A Tool-owned `argument_normalizer:` remains the
  explicit compatibility seam and runs once before validation; approved calls
  persist that canonical value and revalidate against the current schema on
  resume without renormalizing or reevaluating approval. `edit_file` declares
  its existing alias and string-boolean tolerance through that seam and rejects
  alias collisions. Provider replay substitutes `{}` only as the wire placeholder
  for an already rejected call, paired with its error result. Direct `Tool#call`
  remains a trusted host path and skips Agent validation. Task output now uses
  the same JSON resource limits. This is minor-release behavior for hosts whose
  policy or handlers previously received malformed values, whose custom
  validators relied on implicit full-schema authority, or whose code mutated or
  indexed a Tool's raw schema with symbol keys. `Schema.strict` results are now
  deeply frozen, and `Tool.define` raises when both `input_schema:` and `schema:`
  are supplied instead of silently choosing one. Definition compilation is paid
  once; a completed call adds one bounded ownership pass and one compiled schema
  traversal, plus ownership only when a normalizer replaces the value. Streaming
  tool snapshots deep-freeze each newly refreshed bounded preview once; deltas
  that reuse the cached preview are O(1), and pairing strings are copied.
  Completed call envelope verification is one linear pass over that turn's
  calls. Run and resume add one linear control-state read of the session log to
  seed O(1) identity checks. Encoded Anthropic/OpenAI arguments and task text add
  one linear lexical scan before JSON parsing; it is off the token-delta path. A
  normalized approval adds only a small provenance marker. Structured
  output request building adds one bounded schema ownership pass; task plans
  compile their local validator once, with no added work on token streaming.
  Arguments are now deeply frozen before hooks and handlers; hosts that mutated
  model-supplied hashes or arrays must copy them first.
- Provider replay now keeps opaque state with its provider of origin. Gemini
  sends tool schemas through `parametersJsonSchema`, preserves each signed part
  boundary, and returns Google's function-call ID exactly when one was supplied;
  legacy calls without a wire ID get a collision-safe internal ID without
  mutating the signed provider part. On pre-3 Gemini turns, an earlier gated
  same-name/no-ID call is rejected in band if a later sibling would answer
  first; Gemini 3 wire IDs retain out-of-order pairing. A MAX_TOKENS turn never
  executes a returned call. OpenAI treats a missing completed `arguments` field
  as malformed instead of executing `{}`. Anthropic and OpenAI no longer place
  another provider's signatures on their wire. These replay checks add constant
  metadata work per completed block. Terminal records now fence later known
  content for all three providers. Anthropic enforces
  sequential and open content-block indexes plus the delta kind expected by the
  open block. OpenAI enforces one open output item, its kind, any present item or
  output-index correlation, and terminal event/status agreement. Unknown future
  event types remain ignorable. The checks add only constant primitive
  comparisons per known delta, with no parsing, copying, or I/O.
  Completed foreign tool exchanges project to neutral text when a session
  moves to Gemini, preserving the result without manufacturing a Gemini
  function call that lacks Google's thought signature.
  Real providers now emit the same initial `:start` snapshot as the Fake, and
  every opened text, thinking, or tool-call block emits its matching end before
  a terminal failure. Interrupted tool calls remain explicitly incomplete and
  are stripped before Agent persistence; interrupted Anthropic thinking never
  replays a partial signature.
- Tool execution now emits `:tool_started` when each resolved call commits to
  invocation and carries a structured failure fact end to end. A handler may
  return `ToolResult(error: true)`; unknown tools, policy blocks,
  handler exceptions, timeouts, pre-invocation interruptions, failed result
  hooks, healed dangling calls, and MCP `isError` results set it automatically.
  The flag is sticky through `after_tool` rewrites, so changing error text
  cannot relabel a failed operation as successful. `Event#tool_error` is always
  true or false on `:tool_result`; new tool messages persist the same value, and
  legacy messages without it remain unknown and replay with the historical
  unmarked provider shape. Human approval denial remains a normal control
  outcome rather than an execution error. Anthropic receives `is_error: true`;
  Gemini receives the documented `error` function-response key; OpenAI retains
  textual output because its function-call output has no
  execution-error member. Error text is not classified by prefix, and an error
  bit never authorizes a mechanical replay because a side effect may already
  have happened; the model may still choose a new call, so hosts retain
  idempotency and reconciliation policy. `ends_turn` remains the host's stronger
  floor-transfer policy even when a result is errored; `handed_off?` does not
  claim confirmed tool success. The new lifecycle signal adds one synchronous
  sink event per committed call. Partial streaming Event construction adds two
  primitive checks and one immutable nil slot; partial Message construction
  adds one nil check and one immutable nil slot, with no parsing, buffering,
  I/O, or string work. Tool batches add one sentinel write at commitment and one
  identity check per result so a hard worker exit distinguishes started calls
  from untouched queue entries; same-batch ordering adds one short-lived
  identity map and a linear post-join pass, plus a second identity map only when
  `after_tool` is configured;
  starts arrive on serialized worker-thread callbacks, while same-batch results
  still emit in model-call order after the batch joins. `:tool_started` and
  handler-progress subscriber exceptions propagate and never become tool
  failures.
  Unknown, blocked, denied, queued, and pre-invocation interrupted calls add no
  start event.
- A blockless nested object in the tool-schema DSL now declares a freeform JSON
  object instead of leaking `LocalJumpError` during application boot. A bare
  top-level `Schema.build` raises `ConfigurationError` with a useful message.
  Constrained-output preparation now refuses this freeform shape, and directly
  encountered explicitly open objects, with a schema path instead of silently
  closing them and changing their meaning. Existing block-built and raw tool
  schemas keep their wire shape. Tool-schema work remains definition-time;
  constrained-output request building adds one openness check to its existing
  property/item traversal, with no streaming or token-path work.
- Provider and MCP JSON bodies, individual SSE lines, and stdio JSON records
  now default to an 8 MiB ceiling, configurable with `max_record_bytes:`.
  Successful bodies are counted incrementally, declared oversized bodies fail
  before reading, streaming remains unlimited across individually safe records,
  and error responses retain at most a 500-byte valid UTF-8 preview. Requests
  use identity encoding so compressed expansion cannot bypass the boundary.
  Overflow closes the connection or child process; an oversized MCP
  `tools/call` response remains explicitly ambiguous and is never replayed.
  Stdio timeouts now cover the complete record instead of only its first byte;
  any in-flight stdio wire failure after `tools/call` is ambiguous, reaps the
  child, and requires a clean handshake before the next operation. Explicitly
  closing and reusing an MCP client also clears its session, negotiated
  protocol version, and server information before the fresh handshake.
  Each completed SSE record also receives a bounded 20,001-token lexical
  preflight, derived from the 10,000-node canonical limit, plus depth and 64 KiB
  numeric-token ceilings before JSON parsing. A distinct
  `ResponseTooComplexError` preserves the exact boundary and bounds Gemini
  argument allocation inside its enclosing record. Either size or complexity
  overflow resets an MCP wire and its negotiated session. An unconfirmed
  `tools/call` outcome becomes ambiguous and is never replayed; a matching result
  received before an invalid trailing SSE record remains authoritative, while
  the next operation still performs a fresh handshake. Fragmented Anthropic and
  OpenAI tool arguments also carry an aggregate 8 MiB cap across SSE records.
  Their live partial preview stops reparsing after a bounded 64 KiB schedule
  while raw delta events continue unchanged; OpenAI's completed item remains
  authoritative. Fragmented Anthropic thinking
  signatures stop immediately at the same aggregate ceiling rather than
  growing quadratically or replaying a truncated opaque value.
  The hot path adds one byte-count addition and comparison per JSON socket or SSE
  line fragment, then one bounded linear lexical pass over each completed SSE
  record before the provider's existing JSON parse.
- Remote MCP and server-side OAuth requests now default to public HTTPS and
  direct connections. Every DNS answer is checked against the IANA
  special-purpose registries, including embedded NAT64 destinations; one unsafe
  answer rejects the whole set. Approved addresses are pinned without changing
  Host, SNI, or certificate identity, alternates are tried only before request
  transmission, and every connection cycle resolves and validates a fresh DNS
  set, including Net::HTTP's internal reconnect cycles. Redirects and ambient
  proxies cannot bypass the boundary. `allow_non_public:` is a narrow host
  callback for approved internal HTTPS and explicit loopback development.
  Client construction remains DNS-free; a reused socket adds no request-path
  work. A new connection cycle pays one validated DNS lookup, with approved
  candidates tried only before request transmission.
- MCP custom headers are copied at client construction and transport-owned
  headers are rejected; a token callable remains the dynamic authentication
  path. Tool discovery rejects repeated cursors and defaults to at most 100
  pages and 10,000 tools; hosts can adjust either ceiling.
- MCP OAuth discovery now follows the required protected-resource and
  authorization-server candidate order, uses exact candidate-aware resource and
  issuer binding, honors challenge scope, requires S256 PKCE, and never adds
  `offline_access` as gem policy. OAuth response bodies are uncompressed and
  bounded to 256 KiB; token error descriptions cannot reflect credentials into
  exceptions. A pre-registered client now requires its exact trusted `issuer:`,
  and completion and refresh rediscover the token endpoint from that persisted
  issuer instead of trusting a stored endpoint. New confidential flows persist
  an explicit authentication method; legacy rows with a secret and no method
  retain their previous `client_secret_post` behavior.
- The MCP Rails generator now persists `issuer` instead of `token_endpoint` and
  exposes `mcp_allow_non_public` as the host's shared egress-policy hook. Existing
  generated models must add and pass an issuer, restart pending OAuth flows,
  and thread their non-public policy through the client and all OAuth
  operations. Existing connected rows must reconnect unless the application
  independently recorded their exact historical issuer. An issuer must never
  be inferred from a token endpoint.
- GPT-5.6 Sol, Terra, and Luna are catalogued with their 1.05M-token context,
  128K-token output ceiling, and standard paid pricing above and below the
  272K long-context boundary. The `gpt-5.6` alias resolves to Sol. OpenAI usage
  now separates billable GPT-5.6 cache writes from uncached input, keeping
  compaction, reported cost, and cost budgets accurate.
- Directory workspaces reject existing symlinks in model-controlled paths and
  omit symlinked files from listings. In a stable, host-controlled tree, reads,
  writes, and deletes no longer follow a link outside the configured root.
- Streamable HTTP no longer replays an MCP `tools/call` when its response cannot
  be confirmed. The server may already have committed the tool's side effect,
  so the call now raises `AmbiguousDeliveryError` with an explicit do-not-retry
  warning instead of transparently executing twice.
- Refusals and content-filter stops surface honestly on every provider
  instead of reading as clean stops or retryable truncations. Gemini's
  verdict finish reasons (SAFETY, RECITATION, LANGUAGE, BLOCKLIST,
  PROHIBITED_CONTENT, SPII, the image verdicts) and blocked prompts
  (promptFeedback.blockReason, which previously read as a retryable
  truncated stream) fail fast as Mistri::InvalidRequestError with the
  wire word in the message. MISSING_THOUGHT_SIGNATURE is a deterministic input
  failure; its model fumbles and incomplete sentinels
  (MALFORMED_FUNCTION_CALL, UNEXPECTED_TOOL_CALL, TOO_MANY_TOOL_CALLS,
  MALFORMED_RESPONSE, FINISH_REASON_UNSPECIFIED, NO_IMAGE, and the catch-all
  OTHER pair, documented as unknown reasons rather than rulings) error retryably.
  Anthropic's refusal
  stop reason fails fast carrying stop_details' category and explanation
  (the API's guidance is a different model, never a same-model retry),
  and model_context_window_exceeded maps to :length per its guidance.
  OpenAI's incomplete_details content_filter and structured-output refusal
  parts or deltas fail fast instead of reading as a completed answer; unknown
  incomplete reasons retry rather than becoming clean stops. Partial content
  stays on the errored message for hosts to show. Genuinely undocumented future
  Gemini stop reasons still tolerate as clean stops, unchanged. Anthropic and
  OpenAI top-level stream errors now classify documented authentication,
  request/policy, rate-limit, timeout, overload, and server failures by their
  wire code rather than retrying deterministic 4xx errors.
- Active session execution is not yet leased. Store appends from approvals,
  steers, and reports remain concurrency-safe, but hosts must allow only one
  `run` or `resume` at a time for a session. Even with one runner, a crash,
  result-store failure, or subscriber exception after invocation but before
  result persistence can leave an approved call open for possible duplicate
  re-execution. Simultaneous runners widen the same risk. Hosts must use
  idempotency/reconciliation across that commit gap; durable atomic claiming is
  the next synchronization feature, not simulated by a local mutex.
- Sinks::Coalesced is origin-aware and thread-safe: a background worker's
  deltas no longer merge into the parent's (or another worker's) event at
  the same content index, and concurrent emitters serialize on an
  internal mutex instead of racing the buffer. One uncontended mutex
  acquire per event, at coalesced rate; nothing changes on the token
  path.
- OpenAI response.failed events classify by their error code instead of
  all reading as a retryable truncated stream: rate limits and server
  errors stay retryable, timeouts retry, and permanent rejections
  (invalid_prompt, the image family) carry the new
  Mistri::InvalidRequestError shape and fail fast, so the loop no longer
  burns its retry budget on input the provider already ruled out. A
  failed response without an error object now errors instead of reading
  as a clean stop.
- The model catalog carries each model's published standard paid direct-API
  prices. Assemblers price every turn's usage from them: message.usage.cost and
  Result#usage now report list-price dollar estimates for catalogued models, and the
  Budget cost_usd ceiling actually stops a run. It never could before:
  nothing computed cost, so the comparison always saw zero. Pricing is
  selected per request, including GPT-5.4/5.5 and Gemini Pro long-context
  tiers and Sonnet 5's September 2026 rate change. Unpriced usage is marked
  unknown instead of free. A cost ceiling rejects an unknown model or origin
  at construction and fails closed when a request's pricing is unknown at
  runtime. Catalog pricing requires an explicit `catalog_pricing:` opt-in on
  custom origins and observes service-tier policy without changing it;
  nonstandard or unreported tiers stay unknown. A deterministic standard tier
  is required up front for cost-budgeted Anthropic and OpenAI agents; Gemini's
  reported standard, Flex, or Priority tier is honored rather than assuming
  standard. Cost ceilings remain soft and are checked between model-visible
  turns. An unmetered attempt raises Mistri::BudgetError instead of retrying
  under false certainty; the error and an unpriced_attempt session entry retain
  its partial accounting. Run usage includes every retry and compaction attempt,
  and retry session entries now carry their own usage. Truncated streams preserve
  partial token counts but mark their dollar total unknown.
- Compaction now uses the published 1M context windows for catalogued Fable,
  Opus, and Sonnet models and the 1.05M windows for GPT-5.4 and GPT-5.5.
  Automatic headroom protects a full next output plus framing slack when the
  provider shares input and output capacity; Gemini's separately published
  input limit keeps input-only headroom. An explicit `reserve:` still wins as
  host policy.
  `Compaction#automatic_reserve?` lets hosts distinguish the default mode from
  an explicit 16,384-token policy without changing `Compaction#reserve`.
  Usage reported before the latest compaction no longer makes a fresh summary
  appear full. A single run can compact repeatedly across tool turns while
  keeping parallel calls paired with every result. Large tool results are
  bounded only on the lossy summarizer wire, with their beginning and end
  retained. That shortening never mutates the stored result or an ordinary
  request that still replays it. Compacted replay intentionally remains
  summary plus tail. The live
  provider harness now proves two compactions, an exact tool-token handoff,
  and final fact recall inside one run.

## [0.5.0] - 2026-07-08

- The children registry: Session#children lists every sub-agent a session
  has spawned as a Mistri::Child, a window onto the child's own session
  with name, status, report, transcript(tail:) with image bytes stripped,
  and say(text) to steer it. All of it derives from the store, so it reads
  the same from any process, while the child runs and forever after.
- Completion is a contract: every child ends by writing a terminal entry
  (done with its report, stopped, or failed with the error), including
  when the child's run raises, so a crashed child never reads as running.

- Spawn policy is an object: Mistri::Spawner carries the pool, types,
  models, headcount, and dispatcher; SubAgent.spawner and SubAgent.pack
  stay the front doors.
- Typed workers: the spawner takes types:, a host registry of Definitions
  by name. A typed child takes its system prompt, tools, and model from
  the definition; instructions appends; explicit tool and model args
  override within the pool and allowlist. "general-purpose" stays the
  built-in composable default. Types fail at construction, never
  mid-spawn: a definition with unfilled placeholders or tools the pool
  lacks is a boot-time ConfigurationError.
- max_children (default 4) caps live workers per session; a spawn past
  the cap answers in band and freed slots reopen.
- SubAgent.pack returns the spawn tool plus the management console in one
  call, the whole kit for a worker-running agent.

- Background mode: spawn_agent takes mode: "background" when the spawner
  has a dispatcher, returning a truthful receipt immediately (what the
  child's status says after dispatch, not what the mode promised) while
  the parent keeps working; the report arrives on its own (above). The
  dispatcher is a seam: Dispatchers::Inline (default degrade, synchronous
  but honest) and Dispatchers::Thread ship in the gem, and a queue host
  plugs one lambda whose job reconstructs tools from the serializable
  spec and calls SubAgent.run_dispatched.
- Lifecycle is entries: subagent_dispatched and subagent_started join the
  terminal, so status walks the store alone: queued, running, interrupted,
  done, stopped, failed. A job that dies before starting reads :queued,
  honestly.
- A background child runs on its own signal: the parent's turn is over, so
  only stop_agent and the stop flag end it early. workspace: "parent"
  requires inline mode, enforced in band.

- Report delivery: a background child's terminal outcome reports back to
  its parent. The report queues in the parent's inbox as a
  typed subagent_report entry and folds at the next turn boundary the way
  a steer does (the model sees `[Magpie finished] <report>`; failures
  carry the error, stops say so), and a report landing as a run finishes
  cleanly extends it one turn so the parent reacts. A :subagent_report
  event (agent, session_id, status, content) closes the child's lane in
  whatever UI watched the spawn. Session#pending_inbox is the
  steers-and-reports view (hosts that wake idle sessions on steers should
  watch it instead); Session#deliver_report drops sequential duplicate
  delivery by child Session ID. Concurrent callers need serialization.
- With a lock adapter, dispatched runs use the child's lease before the
  run-or-not decision: a queue that redelivers a live job leaves the
  owner alone, a retry of a finished or cancelled child is a clean no-op,
  and a retry of a child a crashed process left mid-run runs it again
  (previously the guard refused it, wedging the child as interrupted
  forever). Child#finished? and Child#error are new readers.

- The management console: Mistri::Console.tools returns list_agents,
  read_agent (tail: to choose how much transcript, wait: to block for the
  report with an in-band timeout), steer_agent, and stop_agent. Every tool
  is a thin wrapper over Session#children and the Child facade, the same
  functions a host UI calls, so agent and user control stay structurally
  equal. Workers answer to name or session id uniformly in every tool;
  duplicate names resolve to the latest spawn, ids stay unambiguous, and
  every state answers honestly in band (already done, nothing to steer,
  stopping needs a lock adapter).

- Stop one child, keep the run: every sub-agent now runs on its own signal
  derived from the parent's (AbortSignal#derive), so the parent's abort
  still cascades down while Child#stop ends a single worker and the parent
  reasons on with "[the X sub-agent was stopped]". Cross-process stops ride
  the lock adapter's flags; the lease thread turns them into the child's
  cooperative abort within a tick.
- A run stopped during its tool phase now reports :aborted. The final
  assistant message is clean in that case, so the message's stop reason
  read :completed and a user-stopped run could claim success; the signal
  is consulted alongside the message.

- The lock adapter: Mistri.locks takes an adapter for cross-process leases
  and flags (Locks::Memory built in; Locks::RailsCache as an opt-in require,
  the Stores::ActiveRecord pattern). Locks.hold keeps a lease alive on a
  heartbeat from a background thread and releases it cleanly, join and all,
  so a mid-renewal tick can never re-stamp a released lease.
- Children gain liveness: every child run holds a lease, and with an
  adapter configured a child that died without writing its terminal entry
  reads :interrupted instead of :running forever. Without an adapter
  nothing changes.

- Session#transcript reads the whole conversation back from the store:
  entries with image bytes stripped, and with include_children every
  sub-agent's log spliced in after its link entry, tagged with an
  "origin" key shaped exactly like the live stream's event origins
  (nesting joined with ">"). A UI that rebuilds from the transcript shows
  the lanes it showed live, running children's progress-so-far included;
  hosts stop hand-walking link entries.

- Tool.define takes ends_turn: true for a tool that is the last word of
  its turn: once it executes, the loop ends the run instead of prompting
  the model again, so an ask_user tool hands the floor to a human
  structurally instead of through prompt discipline. The whole batch it
  arrived in still executes and is answered; a blocked or denied call
  never executed, so the model keeps the floor; a parked approval outranks
  it (the run suspends, and an approved ends_turn call ends the resumed
  run). A pending steer stays queued for the next run. The Result says it
  happened (Result#handed_off?), so hosts route on the handoff instead of
  sniffing messages, and task mode returns the handoff as-is rather than
  re-prompting for JSON while a human holds the floor.

- Store appends tolerate concurrent writers. Sessions have more than one
  appender by design (the loop, a steer from a web process, a worker's
  report from a job), so the ActiveRecord store's unique index is now
  concurrency control rather than a tripwire: a writer that loses the
  position race retries at the next slot, bounded, then raises loudly.
  The JSONL store writes each line in a single call, so concurrent
  appenders interleave whole lines, never fragments.

- The Fake provider streams tool-call arguments in chunks, and each
  delta's partial carries the in-progress call with arguments parsed so
  far, the same shape a real assembler builds. A consumer that renders
  tool input as it arrives (a page preview, a code block) is now testable
  headless.
- Each run of a named specialist can carry its own name: the delegate
  tool takes an optional name argument, so two parallel researchers read
  as Corgi and Beagle in lanes, lists, and links instead of "researcher"
  twice. SubAgent.sanitize_label is the one shared sanitizer behind
  specialist runs and spawner labels.

## [0.4.1] - 2026-07-06

- Terminal events are loop-owned: each attempt's :done or :error is held at
  a gate and only the accepted attempt's terminal reaches the subscriber. A
  transient failure that retries and recovers no longer shows the host an
  error it then walks back, and repeated empty completions no longer emit a
  :done per attempt.
- The :retry event carries structure: attempt, max_attempts, and delay ride
  the event (and its wire form), so a sink can render "Retrying (2/3) in
  1.3s" without parsing prose. The prose note stays as content. The event
  no longer carries a stop reason, because a retry is not a stop.
- RetryPolicy owns attempt classification: error_for(message) returns the
  provider's error or a synthesized EmptyCompletion for a blank answer.
  RetryPolicy::EMPTY_COMPLETION replaces the agent-internal constant.
- The MCP client advertises protocol 2025-11-25, the current spec revision
  it already negotiated.
- README: the :retry event and the terminal-events invariant are documented
  in the reliability section; the MCP section documents eager listing,
  refresh:, and the duplicate-name raise at Agent.new.

## [0.4.0] - 2026-07-05

- Mistri::Definition: agents as frontmatter markdown files. Config in
  YAML, prompt in the body, {placeholders} filled at build time and
  unfilled ones raise. Tool names and extra keys stay the host's
  vocabulary.
- Agent context: Mistri.agent(context: anything) rides the run and reaches
  every tool handler and hook as context.app, untouched.
- Content::Image.from_data_uri accepts base64 data: URIs directly.

- OpenAI reasoning summaries keep their paragraph structure: a reasoning
  item's summary parts join with a blank line, and the boundary streams as
  a thinking delta, so live views match the finished text.

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
  JSON matching the schema: tools run as usual, providers constrain the
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
  Mistri::Sinks: ActionCable (lazy server, injectable), SSE (outbound
  frames to any IO), and Coalesced (merges delta bursts to UI speed), all
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

[Unreleased]: https://github.com/mcheemaa/mistri/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/mcheemaa/mistri/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/mcheemaa/mistri/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/mcheemaa/mistri/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/mcheemaa/mistri/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mcheemaa/mistri/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/mcheemaa/mistri/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mcheemaa/mistri/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mcheemaa/mistri/releases/tag/v0.1.0
