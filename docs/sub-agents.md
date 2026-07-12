# Sub-agents

A sub-agent runs a self-contained task in a new Session. Its exploration stays
out of the parent's context; only the final report returns. The child transcript
remains linked for inspection, streaming, and UI reconstruction.

Mistri supports two shapes on that mechanism:

- a fixed specialist curated by the host;
- a host-bounded spawn tool whose model chooses a name, instructions, type,
  tool subset, model, and execution mode within explicit allowlists.

The open Spawner rejects `spawn_agent` in its own pool, so model-composed
recursive spawning is not available by default. A host may deliberately give a
fixed specialist another specialist or spawn tool; nested origins and
transcripts are supported.

## Fixed specialists

```ruby
researcher = Mistri::SubAgent.new(
  name: "researcher",
  description: "Reads approved sources and answers factual questions.",
  provider: Mistri.provider("claude-haiku-4-5"),
  system: "Research the question. Return findings and source URLs.",
  tools: [fetch_page],
)

agent = Mistri.agent(
  "claude-opus-4-8",
  tools: [researcher.tool],
)
```

Each call creates a fresh child Session in the parent's store. The model may
provide a display name for that run, so parallel specialists can appear as
distinct lanes.

Pass `schema:` to validate a normally completed report as structured output.
An `ends_turn` tool hands off with unvalidated text and `output` nil, so do not
grant one when every report must satisfy the schema. Other Agent options, such
as a budget or compaction policy, pass to the child through
`Mistri::SubAgent.new`.

## The spawn tool

The open spawner lets the parent compose a worker from a pool the host controls:

```ruby
spawn = Mistri::SubAgent.spawner(
  provider: child_provider,
  tools: [fetch_page, search_catalog],
  models: ["claude-haiku-4-5", "gpt-5-nano"],
  max_children: 4,
)

agent = Mistri.agent("claude-opus-4-8", tools: [spawn])
```

The generated `spawn_agent` tool asks for a complete task and system
instructions. The model may select only tools in the pool and only model IDs in
`models:`. Without an explicit model, an inline child inherits the supplied
provider object. A background child records that provider's model identity and
the Runtime factory reconstructs its provider inside the worker.

Do not place `spawn_agent` inside its own tool pool. Mistri rejects that host
configuration.

### Typed workers

Definitions let the host own a worker's base prompt and its default tools and
model:

```ruby
types = {
  "researcher" => Mistri::Definition.load("agents/researcher.md"),
  "reviewer" => Mistri::Definition.load("agents/reviewer.md"),
}

spawn = Mistri::SubAgent.spawner(
  provider: child_provider,
  tools: [fetch_page, search_catalog, inspect_record],
  types: types,
  models: ["claude-haiku-4-5"],
)
```

A typed worker always begins with its Definition's rendered prompt. The model
may append focus instructions, choose another subset from the host's tool pool,
and select another model from the explicit allowlist. Without those overrides,
the Definition's declared tool names and model are the defaults. Definitions
are checked when the spawner is built, so a missing pool tool or unresolved
placeholder fails before a model can spawn. Use a fixed `Mistri::SubAgent` when
the worker's tools and model must not be model-selectable.

`general-purpose` remains the built-in open type and requires model-written
instructions.

## Execution modes

Without a dispatcher, a child runs inline inside the tool call. The parent waits
for the report, and its abort signal cascades to the child.

Add a dispatcher to expose `mode: "background"`:

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
  )
end

tools = Mistri::SubAgent.pack(
  provider: child_provider,
  tools: [fetch_page, search_catalog],
  dispatcher: Mistri::Dispatchers::Thread.new,
  runtime_factory: runtime_factory,
)
```

`pack` returns the spawn tool plus `list_agents`, `read_agent`, `steer_agent`,
and `stop_agent`. A dispatcher always requires `runtime_factory:`. The static
provider, tool pool, types, and model allowlist declare what the model may
request. The factory constructs what one background child may actually use.

`Mistri::SubAgent::Runtime` holds the provider, system prompt, exact tools, an
optional `cleanup:` callable, and safe Agent options for one execution:
`budget`, `max_concurrency`, `transform_context`, `compaction`, `retries`,
`before_tool`, `after_tool`, and application `context`. `skills:` is refused in
a background Runtime because Agent would add a `read_skill` tool outside the
durable grant. Lifecycle keywords such as `session`, `task`, `signal`, and
`emit` are never Agent options; the child boundary owns them. The same option
validation applies to fixed specialists and Spawner. Spawner-level Agent
options still apply only to inline children; put a background child's options
on its Runtime.

Mistri calls the factory inside the worker after ruling out a finished
redelivery. While a configured child lease remains live, it also rules out an
ordinary concurrent delivery first. It then requires the runtime provider's
model and the unique runtime tool names to match the versioned dispatch spec
exactly.
Missing, additional, renamed, duplicated, or statically approval-gated runtime
tools fail the child before a provider call or tool side effect. Runtime tools
are reordered to the durable grant so provider prompt order is deterministic.
Mistri calls `cleanup` exactly once for a Runtime the factory returned,
including after validation or execution failure. A cleanup failure does not
replace an active primary error; by itself it raises after the terminal result
and report are durable. Use it to release per-child providers, MCP clients, or
other connections. Mistri does not guess which objects the host owns.

The model has no workspace selector. Derive resource scope from trusted host
state and stable identifiers such as the child Session ID, not from its name,
task, or instructions. Reconstructing a Ruby object is not itself isolation:
the host must decide whether two runtimes use separate directories, database
rows, credentials, MCP clients, or other backends. Use the same deterministic
child scope on a queue retry rather than creating a random empty workspace.

### Thread dispatcher

`Mistri::Dispatchers::Thread` starts a Ruby thread and returns a receipt to the
parent immediately. The runtime factory executes on that thread. The host must
still construct fresh or deliberately shared dependencies; a Proc can close
over any object, and Mistri does not pretend to inspect its closure. The Thread
dispatcher is useful for development and short work in a process whose
lifetime the host controls. It is not a durable job queue.

### Queue dispatcher

A production host can dispatch the serializable spec to its queue:

```ruby
dispatcher = lambda do |spec, _in_process_runner|
  RunMistriChildJob.perform_later(spec)
end
```

The spec is a deeply owned, immutable, bounded JSON Hash containing a spec
version, child and parent Session IDs, worker type, model-written instructions,
task, exact tool names, and model ID. The identical canonical spec is stored in
the child Session before dispatch. `run_dispatched` compares the complete queue
copy with that durable grant before checking a finished result, constructing a
Runtime, or routing a report. A changed grant, task, model, name, or parent ID
raises `Mistri::DispatchGrantError` and leaves the legitimate child untouched.
The unchanged queue item cannot heal: configure the job system to discard it
and alert an operator. The class is reserved for Mistri's stored-grant binding;
a runtime factory must not use it as an application signal. Versioned specs
reject unknown fields.

Unversioned 0.5 queue specs remain executable because their child entries did
not store a comparable grant. That compatibility cannot retroactively prove
their queue copy or report routing. Drain or inspect those jobs before relying
on the versioned boundary.

The spec contains no providers, tools, workspaces, credentials, or callbacks.
If queue execution needs a tenant or account ID, put that trusted identifier
beside the spec in the host's job envelope and reauthorize it in the worker; do
not add fields to the spec or put live application objects inside it.

The job invokes the same host registry locally, then enters the shared child
lifecycle:

```ruby
Mistri::SubAgent.run_dispatched(
  spec,
  store: mistri_store,
  emit: event_sink,
  runtime_factory: HostAgents.method(:runtime_for),
)
```

The factory itself is host code and is never serialized. Existing jobs may
continue to pass directly reconstructed `provider:`, `system:`, and `tools:` to
`run_dispatched`; Mistri applies the same exact model and capability checks.
Prefer the factory form because it runs after the stored terminal check and,
with a configured lock adapter, successful child-lease acquisition. It avoids
constructing credentials, connections, or workspaces for a finished delivery
and for an ordinary concurrent delivery while that lease remains live.

An exception raised while the queue's factory is constructing dependencies is
retryable by default: `run_dispatched` releases the lease, leaves no terminal,
and re-raises so the queue can retry. Runtime contract mismatches are terminal.
On a queue's final attempt, pass `retry_factory_errors: false` to record and
report the construction failure before the exception re-raises. The flag does
not decide whether the job system retries or discards the exception. The
in-process runner already uses terminal behavior because Thread and Inline have
no durable retry owner.

The factory boundary applies to dispatched children. Inline spawns and fixed
specialists continue to use the provider and Tool objects supplied by the host;
parallel inline calls may therefore share whatever those objects close over.
That is deliberate host policy, not an isolation guarantee.

## Reports and control

A background spawn returns a truthful receipt based on the child's stored
status. When the child reaches a terminal state, it writes its result to its own
session and delivers one typed report into the parent inbox.

An inactive queued or interrupted cancellation owns that durable inbox delivery
while it holds the child lease, so the parent receives the stopped report even
if the queue never starts or retries the job. The callback-only
`:subagent_report` event is not emitted for that host-initiated path because
`Child#stop` has no event sink; the durable parent inbox is authoritative.
If that cross-session inbox append raises, the stopped terminal remains
durable. Repeating `Child#stop` or `stop_agent` retries the report under the
child lease and sequentially deduplicates an earlier successful delivery.

The parent folds that report at its next turn boundary as a labeled message.
The `:subagent_report` event closes the worker's live UI lane. Duplicate report
delivery is dropped by child Session ID when redeliveries are sequential. The
current check is not an atomic uniqueness constraint, so a queue must serialize
delivery or deduplicate concurrent attempts in host storage.

Host code and the management tools use the same `Mistri::Child` facade:

```ruby
child = parent_session.children.first

child.status                   # :queued, :running, :interrupted, :done, :stopped, :failed
child.report                   # terminal report when done
child.error                    # terminal error when failed
child.transcript(tail: 20)     # presentation-oriented recent entries
child.say("Check pricing too") # queues a steer
child.stop                     # durable if inactive, cooperative if running
```

`read_agent` with `wait: true` waits for a terminal, including across an
interrupted worker's later queue retry or cancellation. Abort and timeout still
end the wait in band.

Stopping requires a lock adapter. A queued or interrupted child that has no
current lease owner is terminalized and reported immediately under a lease. If
a runner already owns the lease, the cross-process flag requests its
cooperative abort instead.

Child events forwarded into the parent stream carry an `origin` such as
`Corgi#ab12cd34`. `session.transcript(include_children: true)` uses the same
labels when rebuilding lanes from the store.

Like `Session#transcript`, a child transcript only strips inline image bytes. It
is not an authorization or redaction boundary; authorize and redact it before
exposing it.

## Provider concurrency

Several spawn calls in one parent turn are tool calls and can begin
concurrently. Actual model requests depend on provider instances:

- Inline calls sharing one built-in provider object serialize through that
  provider's transport.
- A background Runtime factory decides whether children receive independent or
  deliberately shared providers. Distinct instances are required when their
  model calls must overlap.
- An inline typed Definition with its own model builds a provider for that
  worker. A background typed worker records the model identity and relies on
  the Runtime factory to construct it.

This distinction avoids promising network fan-out when only tool scheduling is
parallel.

## Approval

A child cannot suspend and wait for a human. It must return a report to its
parent.

Mistri rejects statically approval-gated tools when a SubAgent or Spawner is
built. A predicate gate cannot always be detected statically; if one triggers at
runtime, Mistri denies and settles the call, fails the child, and leaves no open
approval.

Gate the delegation itself instead:

```ruby
reviewer = Mistri::SubAgent.new(
  name: "external_reviewer",
  description: "Sends material to the external review service.",
  provider: reviewer_provider,
  tools: [external_review],
  needs_approval: true,
)
```

## Lock adapters

Cross-process liveness and stop requests require a shared lock adapter. Configure
one at boot:

```ruby
# One process, including the thread dispatcher:
Mistri.locks = Mistri::Locks::Memory.new
```

Rails cache support is optional and must be required explicitly:

```ruby
require "mistri/locks/rails_cache"

Mistri.locks = Mistri::Locks::RailsCache.new(cache: Rails.cache)
```

The cache must implement atomic `unless_exist` writes and be shared by every
worker process. A local memory cache is not a cross-process adapter.

A custom adapter implements:

```text
acquire(key, ttl:) -> boolean
renew(key, ttl:)
release(key)
held?(key) -> boolean
set_flag(key, ttl:)
flag?(key) -> boolean
clear_flag(key)
```

The current lease is a best-effort duplicate-suppression and liveness signal,
not an ownership token or exactly-once fence. It stores no holder identity. A
process stalled beyond the TTL can resume after another process acquires the
same key, and unconditional renewal or release cannot distinguish those
generations.

Queue jobs must therefore keep child work idempotent or reconcilable. A held
lease suppresses an ordinary redelivery while the first worker is healthy; an
expired lease allows a retry of a child that appears interrupted. A finished
child's terminal entry makes a later matching delivery a no-op. Calling
`Child#stop` while the child is interrupted competes for the lease and, when it
wins, replaces that possible retry with a durable stopped terminal.

Without an adapter:

- inline and dispatched work can still run;
- a non-terminal started child reads `:running`, because no shared liveness
  signal exists;
- `Child#stop` cannot send a cross-process request;
- queue redeliveries receive no lease-based suppression.

## Capacity is advisory

`max_children` counts the parent's currently live children before spawning. It
is a useful model-facing limit, but the read-then-create sequence is not an
atomic distributed admission control. Concurrent parent runners are already
outside the Session execution contract, and independent callers can race the
count.

If worker capacity is a hard operational limit, enforce it atomically in the
host queue, database, or scheduler. Keep `max_children` as the in-band guidance
the model sees.

## Related guides

- [Sessions and control](sessions.md)
- [Tool contracts](tool-contracts.md)
- [Reliability](reliability.md)
- [Upgrading](../UPGRADING.md)
