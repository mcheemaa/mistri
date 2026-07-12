# Upgrading Mistri

Mistri follows SemVer from 0.x: patches fix behavior, while a minor release may
add features and intentional contract changes. Every change belongs in the
[changelog](CHANGELOG.md); this guide extracts only the work an existing host
may need to perform.

Upgrade a representative application and persisted session set in staging
before production. Do not treat a passing bundle update as a session migration
test.

## From 0.5.x to 0.6.x

This is a safety-focused minor upgrade. The built-in Anthropic, OpenAI, and
Gemini providers preserve ordinary 0.5 sessions, including the repeated
`call_N` IDs older Gemini and Fake-provider turns generated after the earlier
occurrence settled. There is no blanket session rewrite step.

Hosts that used implicit tool schemas, mutated arguments, supplied custom
providers or Session stores, dispatched background children, generated MCP
OAuth models, stored sessions in MySQL, or configured cost budgets need to
review the sections below.

### Checklist

- [ ] Declare every argument a model may send to a formerly schema-less tool.
- [ ] Remove handler or policy mutations of model argument hashes and arrays.
- [ ] Replace implicit coercion with an explicit per-tool normalizer where it is
      genuinely part of the contract.
- [ ] Make event subscribers tolerate new event types and read `tool_error`
      structurally.
- [ ] Ensure at most one `run` or `resume` is active per Session across all
      processes.
- [ ] Treat each approval as single-assignment; resolve quorum or multi-reviewer
      policy in the host before calling `approve` or `deny`.
- [ ] Verify every successful custom Session-store append is visible to later
      loads in the same stable per-session order.
- [ ] Audit custom provider tool-call IDs, names, arguments, and metadata.
- [ ] Widen Active Record session payloads to LONGTEXT on MySQL or Trilogy.
- [ ] Update generated MCP OAuth models to persist issuer and share egress
      policy across the complete flow.
- [ ] Review the new MCP and provider response limits and ambiguous-delivery
      behavior.
- [ ] Configure a deterministic standard service tier for any cost budget.
- [ ] Remove intentional symlinks from model-controlled Directory workspaces.
- [ ] Add a runtime factory to every background spawner and queue worker.
- [ ] Review queued child specs and ensure their exact `tool_names` grant is
      still intended before executing them under 0.6.
- [ ] Exercise active persisted sessions, approvals, tool failures, compaction,
      and one real call per configured provider in staging.

## Background children reconstruct their runtime

A dispatcher no longer captures the spawn-time provider, Tool objects, Agent
options, or their workspace closures. Every spawner with `dispatcher:` must now
provide a host-owned `runtime_factory:`. Mistri invokes it inside the worker and
requires a `Mistri::SubAgent::Runtime`:

```ruby
runtime_factory = lambda do |spec|
  workspace = HostWorkspaces.for_child(spec.fetch("session_id"))
  provider = HostModels.build(spec.fetch("model"))
  tools = HostTools.build(spec.fetch("tool_names"), workspace: workspace)

  Mistri::SubAgent::Runtime.new(
    provider: provider,
    system: HostAgents.system_for(spec),
    tools: tools,
    cleanup: -> { HostAgents.release(provider: provider, tools: tools) },
    budget: HostAgents.child_budget,
  )
end

spawn = Mistri::SubAgent.spawner(
  provider: child_provider,
  tools: declared_tools,
  dispatcher: Mistri::Dispatchers::Thread.new,
  runtime_factory: runtime_factory,
)
```

The provider model and unique Tool names returned by the factory must match the
versioned dispatch spec exactly. Mistri rejects missing, additional, duplicate,
renamed, or reconstructed statically approval-gated tools before the provider
runs. This turns `tool_names` into a durable capability grant rather than queue
metadata. A versioned spec and its exact parent routing are also stored in the
child Session; a changed queue copy raises without failing or reporting the
legitimate child.

`cleanup:` is optional and called exactly once after Mistri accepts a Runtime,
including after validation or execution failure. Use it for per-child provider
sockets, MCP subprocesses, and other host-owned resources. It never masks the
primary error. `skills:` is rejected because it would add an
undeclared `read_skill` tool. Spawner Agent options apply only to inline
children; declare background Agent options on the Runtime.

Sub-agent Agent options are now limited to `budget`, `max_concurrency`,
`transform_context`, `compaction`, `retries`, `skills`, `before_tool`,
`after_tool`, and application `context`; background Runtime still rejects
`skills`. Lifecycle keys such as `session`, `task`, `signal`, and `emit` are
owned by the child and cannot be overridden through generic keyword options.

The model-facing `workspace` argument has been removed. It never cloned a Tool
closure or proved isolation. Existing queued specs that contain `workspace`
remain readable, but new specs omit it. Build child-scoped resources from
trusted host state and stable identifiers such as `session_id`; a retry should
reopen the same durable scope. Inline children still use the exact objects the
host supplied and may share their backends.

Queue jobs should pass the factory into the lifecycle entry point:

```ruby
Mistri::SubAgent.run_dispatched(
  spec,
  store: mistri_store,
  runtime_factory: HostAgents.method(:runtime_for),
)
```

Factory exceptions are retryable by default: the child remains non-terminal
and the exception returns to the queue. Pass `retry_factory_errors: false` on a
final attempt to persist and report the failure before the exception re-raises.
The flag does not control the job system's retry or discard decision. The
built-in Thread and Inline runners use terminal behavior because they have no
durable retry owner.

If the queue copy differs from the stored grant, `run_dispatched` raises
`Mistri::DispatchGrantError` without touching the legitimate child. Treat the
unchanged job as poison: discard it and alert rather than retrying it. This
error is reserved for Mistri's stored-grant binding; do not raise it from a
runtime factory.

The compatible direct `provider:`, `system:`, and `tools:` form remains, but it
now receives the same exact model and tool-grant validation. A job that used to
pass its entire registry must instead reconstruct only the Tool objects named
by `spec.fetch("tool_names")`.
Legacy 0.5 specs keep their serialized grant, including any broad grant created
by the old empty-Definition bug. Their old child entries also have no stored
copy against which Mistri can verify capability or report-routing changes.
Drain or review unversioned queued work before relying on the new boundary.

Tool selection now distinguishes omission from an explicit empty list. Omitted
`tools` means the general pool or a typed Definition's defaults. `tools: []`
means no tools for either worker shape, and a typed Definition that declares no
tools no longer inherits the general pool.

## Tool schemas are enforced locally

Model-originated arguments now cross ownership and schema validation before
`before_tool`, approval predicates, `ends_turn`, MCP, or handlers.

Invalid input receives a bounded error result the model can correct. Valid
sibling calls still run. Mistri does not coerce values.

### Schema-less tools are closed

In 0.5, the no-argument wire schema did not explicitly reject extra fields. In
0.6, a tool without `schema:` or `input_schema:` is a closed no-argument tool.

No change is needed when the tool truly accepts no arguments:

```ruby
Mistri::Tool.define("current_time", "Returns the current time.") do
  Time.now.utc.iso8601
end
```

Declare every accepted field when the handler uses arguments:

```ruby
Mistri::Tool.define("lookup", "Looks up one account.", schema: lambda {
  string :account_id, "Account ID", required: true
}) do |args|
  Accounts.fetch(args.fetch("account_id"))
end
```

For an intentionally freeform object, say so explicitly:

```ruby
input_schema = {
  type: "object",
  additionalProperties: true,
}
```

The schema-less wire shape changes once, so provider prompt caches for affected
tool sets will re-warm after deployment.

### Supplied objects remain open by default

JSON Schema object properties do not close the object. If extra keys must fail,
use a raw schema with `additionalProperties: false`. Otherwise extract declared
fields instead of mass-assigning the complete argument hash.

### JSON Schema dialect and subset

Tool schemas use JSON Schema 2020-12. Replace legacy tuple-array `items: [...]`
with `prefixItems`. A supplied explicit older dialect is rejected.

Core enforces its documented portable subset. Use `argument_validator:` for
domain additions and `complete_argument_validator:` only when the host
validator implements the entire schema. Argument-applicable non-empty
`patternProperties` requires complete authority. External references are never
resolved.

Task mode now rejects an assertion Mistri cannot guarantee locally instead of
claiming validated output and leaving part of the schema to provider guidance.
Freeform objects cannot become strict task output without changing meaning.

See [Tool contracts](docs/tool-contracts.md).

### Schema objects are canonical and immutable

`Tool#input_schema` and `Schema.strict` now expose deeply frozen canonical JSON
with String keys. Replace Symbol-key access and mutation:

```ruby
# Before
tool.input_schema[:properties][:account_id] = rule

# After
account_schema = tool.input_schema.fetch("properties").fetch("account_id")
```

Build a new schema when the host needs a changed contract. `Tool.define` now
rejects supplying both `schema:` and `input_schema:`; choose one. Calling
`Schema.build` without a block now raises because it declares no argument
intent.

## Arguments are immutable and policy sees validated types

Completed arguments and the canonical schema are deeply frozen. Code that
mutated model input must copy the portion it owns:

```ruby
# Before: mutates the value shared with policy and replay.
args["tags"] << "processed"

# After: build application-owned data.
tags = args.fetch("tags", []).dup
tags << "processed"
```

For a fully mutable JSON copy:

```ruby
owned = JSON.parse(JSON.generate(args))
```

Approval predicates can now rely on declared types. Remove defensive coercion
that changes authorization meaning:

```ruby
# Do not turn "all" into zero at an authorization boundary.
approval_policy = ->(args) { args.fetch("total_usd") > 500 }
```

When a host intentionally accepts a legacy alias or representation, use
`argument_normalizer:`. Its output is what validation, policy, approval, and
the handler see. It runs once before validation and does not run again on
resume.

Direct `Tool#call` remains a trusted host path. It applies the tool's normalizer
but does not invoke the Agent's model-input validation boundary.

## Tool lifecycle and event subscribers

Tool results now carry a structured error fact. A handler may return
`Mistri::ToolResult.new(content: ..., error: true)`, and Mistri sets the same
fact for invalid, blocked, unknown, interrupted, timed-out, or failed calls.

`:tool_started` is emitted only when a resolved call commits to handler
invocation. `:tool_result` always carries a boolean `event.tool_error`; new
persisted tool messages carry the same value. Legacy messages without the field
remain unknown rather than being classified from prose.

`:tool_started` and handler progress callbacks originate on tool worker threads.
Custom sinks must be thread-safe. Code that manually constructs a
`:tool_result` `Mistri::Event` must now supply a boolean `tool_error` matching
the Message.

Update exhaustive event switches to ignore unknown future members:

```ruby
case event.type
when :text_delta
  stream(event.delta)
when :tool_started
  mark_running(event.tool_call)
when :tool_result
  settle(event.tool_call, failed: event.tool_error)
else
  # Event types are an extensible union.
end
```

Do not decide failure by matching prefixes such as `"Error:"`. Human denial is
an expected control result and is not marked as execution failure.

The error fact never authorizes mechanical replay. A handler can commit a side
effect before it raises.

Public value records gained fields: `ToolCall` adds `arguments_error` and
`provider_call_id`, `ToolResult` adds `error`, and Message/Event records add
`tool_error`. Keyword construction remains compatible through defaults, but
exact positional deconstruction or pattern matching can break. Prefer named
accessors and key patterns, and treat value and event records as extensible.

## Custom provider contract

Built-in providers already satisfy the new envelope. A custom provider must
return completed `Mistri::ToolCall` values with:

- a non-empty, valid UTF-8 String ID;
- an ID unique for new calls over the active Session;
- a non-empty, valid UTF-8 String name;
- a JSON object for valid arguments, or a durable `arguments_error` for
  malformed encoded input;
- non-empty valid UTF-8 signature and provider call ID strings when present;
- provider correlation IDs unique within an assistant turn.

If any completed call makes the assistant turn unpairable, Mistri rejects the
whole provider attempt before persistence, policy, or sibling execution. The
ordinary provider retry asks for a clean turn with unchanged history.

`ToolCall#arguments_error?` is the stable predicate. Its non-nil String is an
opaque diagnostic, not a public enum.

Audit active custom-provider sessions without mutating them:

```ruby
active_session_ids.each do |session_id|
  session = Mistri::Session.new(store: store, id: session_id)
  session.tool_control_state # validates persisted call and approval identity
end
```

The legacy repeated `call_N` exception is deliberately limited to settled 0.5
Gemini and Fake-provider history without provider correlation IDs. Do not copy
that shape into a custom provider.

Fake-provider call IDs are now namespaced instead of restarting at `call_1`,
`call_2`, and so on. Script an explicit `id:` when a test or persisted fixture
needs deterministic identity.

If an old custom log contains malformed IDs that cannot be paired safely, keep
the old application version available long enough to complete or retire that
session according to host policy. Do not invent replacement IDs in replay; they
would corrupt tool-result correlation.

## Approval decisions are single-assignment

The first valid approval decision in the Session store's durable order is
final. Repeating the same `approve` or `deny` call is idempotent and does not add
another entry once the winner is visible. The first note also wins. A later
conflicting call raises `Mistri::ConfigurationError`; it cannot revoke the
winner.

Two callers can still read the parked request before either appends. Both
attempts may therefore appear in the raw append-only log. Mistri re-reads the
ordered history after append so the winner returns normally and a conflicting
loser raises. Losing entries are validated but inert, including a stale loser
that arrives after the tool result. They no longer make the Session require a
repair step.

This is single-assignment, not quorum. If two people must agree, or a denial
must outrank an approval, implement that policy transactionally in the host and
call Session only after the host has one final decision. A custom Session store
must make a successful append visible to subsequent loads while preserving its
stable total order.

## Session stores

### MySQL and Trilogy payload width

The generated Active Record session table now uses LONGTEXT for `payload`. An
existing table is not changed by updating the generator:

```ruby
class WidenAgentEntryPayload < ActiveRecord::Migration[7.2]
  def change
    change_column :agent_entries, :payload, :text, size: :long, null: false
  end
end
```

Use the migration version appropriate for the host application. PostgreSQL
`text` needs no width change.

### Store value ownership

`Mistri::Stores::Memory` now owns data on append and returns fresh mutable
snapshots on load, matching stores that decode JSON on every read. A custom
store should not rely on Mistri mutating a previously returned entry object.

### Active Session execution

Mistri does not lease top-level Session execution. The host must ensure that at
most one `run` or `resume` is active for a Session across all processes.
Concurrent-safe store appends and child lock adapters do not provide this
guarantee. Keep external writes idempotent or reconcilable across the
handler-commit/result-append gap.

`Session#entries` and serialized usage are extensible records. Raw host readers
must ignore unknown entry types and keys. This release adds lifecycle, approval
provenance, unpriced-attempt, and `cost.known` data.

## MCP changes

### Existing generated OAuth models

The 0.5 Rails MCP generator stored `token_endpoint`. The current flow persists
the authorization-server `issuer` and rediscovers the token endpoint from that
exact identity before code exchange and refresh.

For an existing generated model:

1. Add an `issuer` String column.
2. Persist `flow["issuer"]` in `connect` instead of trusting
   `flow["token_endpoint"]`.
3. Pass `issuer:` to `OAuth.complete` and `OAuth.refresh`.
4. Keep and pass `token_auth_method`.
5. Add one class-owned `mcp_allow_non_public` policy and pass it to
   `OAuth.start`, `.complete`, `.refresh`, and `MCP::Client` when internal
   destinations are allowed.
6. Restart pending OAuth flows.
7. Reconnect existing rows unless the application independently recorded the
   exact issuer used during registration.

Mistri no longer adds `offline_access`; include it explicitly in `scope:` only
when host policy and the authorization server require it. The former implicit
localhost allowance is also gone. Loopback HTTP development now needs an
explicit `allow_non_public: ->(_uri, address) { address.loopback? }` through the
complete flow. A pre-registered client, or discovery advertising multiple
authorization servers, requires the exact trusted `issuer:`.

Never infer an issuer from a token endpoint. They are different security
identities. An unused legacy `token_endpoint` column may be removed in a later
host migration after rollback needs have passed.

Compare the generated files in
[`lib/generators/mistri/mcp/templates/`](lib/generators/mistri/mcp/templates)
with the host copy. Updating the gem never rewrites generated application code.

### Network policy

Remote MCP and server-side OAuth now default to public HTTPS, validated DNS,
direct connections, no redirects, and no ambient proxy. An internal server must
receive the same narrow `allow_non_public:` callback through the entire flow.

Custom headers are copied when the Client is constructed, and transport-owned
framing, MCP session, and protocol names are rejected. Use the token callable for
rotating authorization. Deployments that require an ambient forward proxy or
HTTP redirects need a host-supplied client; the built-in Client deliberately
connects directly.

### Response limits and delivery

JSON bodies, individual SSE lines, and stdio records default to 8 MiB per
record. Set a larger `max_record_bytes:` only for a trusted server after
reviewing the memory boundary.

Provider records use `provider_options: { max_record_bytes: ... }`; the MCP
Client takes `max_record_bytes:` directly. Servers exceeding the new default of
100 discovery pages or 10,000 tools must set reviewed `max_tool_pages:` and
`max_tools:` values explicitly.

An unconfirmed `tools/call` response now raises
`Mistri::AmbiguousDeliveryError` and is never replayed automatically. Catch it
when calling the Client directly, mark the operation for reconciliation, and
verify remote state before deciding whether a new call is safe. A Client used
through `Mistri::MCP.tools` raises inside the tool executor, which returns the
same uncertainty as an error-marked tool result. The transport still does not
replay it, but the model may choose to issue a new call.

### MCP schemas

Mistri enforces directly reachable portable assertions and lets the MCP server
enforce standard assertions outside that subset. Common map schemas with
schema-valued `additionalProperties` work in core. Use a complete validator only
when local policy depends on the whole schema.

An explicit `inputSchema: null` now rejects. Omit `inputSchema` for a closed
no-argument tool, or provide an object schema.

See [MCP](docs/mcp.md).

## Cost budgets and pricing

0.5 exposed a cost budget but did not calculate provider cost, so the comparison
effectively saw zero. 0.6 prices catalogued standard paid direct-API usage and
represents unknown cost as unknown.

A `cost_usd` budget now fails at construction unless the model, origin, and
service-tier policy can produce deterministic catalog pricing. Configure:

```ruby
# Anthropic
anthropic_options = { service_tier: "standard_only" }

# OpenAI
openai_options = { service_tier: "default" }
```

Gemini's omitted tier is standard. Flex, Priority, an unreported nonstandard
tier, an unknown model, or a custom origin remains unpriced unless the custom
provider supplies complete known cost.

Without a cost budget, unknown models and custom origins continue to work.
Inspect `result.usage.cost.known?` before presenting an estimate.

Budgets remain soft ceilings checked between model-visible turns. A final turn
and its retries may cross the configured amount.

## Compaction behavior

Catalogued Anthropic and OpenAI windows now use their published long-context
limits. Automatic reserve protects the model's full shared output capacity plus
framing slack; Gemini keeps its separately published input-oriented reserve.

Sessions with default compaction will therefore compact at different and more
accurate boundaries. An explicit `reserve:` remains host policy and wins.

Compaction can occur more than once inside one run while preserving tool-call
pairing. The full entry log remains exact; replay after a successful compaction
intentionally becomes the visible summary plus kept tail.

Review any UI or alerting code that assumed the old early thresholds. Only the
`:compaction` event carries the summary; `:compacting` is the start signal.

## Provider refusal and stream behavior

Documented provider refusals, content-policy stops, and invalid requests now
fail fast instead of looking like clean completion or consuming retries on the
same rejected input. Unknown transient stream failures still follow the retry
policy.

Interrupted tool calls and partial Anthropic thinking signatures are removed
before persistence. Built-in stream assemblers now enforce known lifecycle,
index, and terminal-record invariants while ignoring unknown future event types
for forward compatibility.

If host code classified provider errors by prose, move to the typed
`result.errored?`, `result.message.error`, `result.stop_reason`, and structured
event or message fields. Built-in provider refusals finish in the Result
contract; they are not raised as ordinary transport exceptions.

## Directory workspaces

Directory workspaces no longer follow existing symlinks in model-controlled
paths and omit symlinked entries from listings. Replace intentional links with
host-controlled tools or real files inside the workspace root. This boundary is
deliberate and has no opt-out in the model-controlled file tools.

## Verification before production

At minimum:

1. Run the hermetic suite and application tests.
2. Audit active persisted sessions with `tool_control_state`.
3. Resume a 0.5 Anthropic session with tool calls and reasoning.
4. Resume a 0.5 Gemini session containing tool calls from more than one turn.
5. Exercise one approval grant and denial after rebuilding current policy.
6. Run a write tool with an idempotency key and simulate failure before result
   persistence in the host test harness.
7. Reconnect and refresh one MCP OAuth connection.
8. Run the provider-specific live tests and integration matrix with every
   expected key present.

```console
$ bundle exec rake test
$ bundle exec rubocop
$ MISTRI_LIVE=1 bundle exec rake test
$ bundle exec rake integration
```

Missing provider keys skip live coverage. Read the output and verify the models
that actually ran.

For exact behavior and latency notes, read the [Unreleased](CHANGELOG.md#unreleased)
changelog entry.
