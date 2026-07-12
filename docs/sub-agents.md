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
`models:`. Without an explicit model, the child inherits the supplied provider
object.

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
tools = Mistri::SubAgent.pack(
  provider: child_provider,
  tools: [fetch_page, search_catalog],
  dispatcher: Mistri::Dispatchers::Thread.new,
)
```

`pack` returns the spawn tool plus `list_agents`, `read_agent`, `steer_agent`,
and `stop_agent`.

### Thread dispatcher

`Mistri::Dispatchers::Thread` starts a Ruby thread and returns a receipt to the
parent immediately. It is useful for development and short work in a process
whose lifetime the host controls. It is not a durable job queue.

### Queue dispatcher

A production host can dispatch the serializable spec to its queue:

```ruby
dispatcher = lambda do |spec, _in_process_runner|
  RunMistriChildJob.perform_later(spec)
end
```

The job reconstructs current tools, provider, Definition, and policy from host
registries, then enters the shared child lifecycle:

```ruby
Mistri::SubAgent.run_dispatched(
  spec,
  provider: HostAgents.provider_for(spec),
  system: HostAgents.system_for(spec),
  tools: HostAgents.tools_for(spec),
  store: mistri_store,
  emit: event_sink,
)
```

Treat that code as an architectural shape, not a copy-paste registry API. The
host owns serialization and reconstruction because application tools commonly
close over credentials, tenants, database objects, or framework state that
must not ride in a queue payload.

`workspace: "parent"` is rejected for background mode, but this field is a
model-supplied scheduling declaration, not capability isolation. Choosing or
omitting `workspace: "own"` does not clone Tool objects or the workspace objects
they close over. A production dispatcher must reconstruct background tools with
isolated, host-owned workspace instances; otherwise parent and child can mutate
the same resource concurrently.

## Reports and control

A background spawn returns a truthful receipt based on the child's stored
status. When the child reaches a terminal state, it writes its result to its own
session and delivers one typed report into the parent inbox.

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
child.stop                     # cooperative; requires a lock adapter
```

Child events forwarded into the parent stream carry an `origin` such as
`Corgi#ab12cd34`. `session.transcript(include_children: true)` uses the same
labels when rebuilding lanes from the store.

Like `Session#transcript`, a child transcript only strips inline image bytes. It
is not an authorization or redaction boundary; authorize and redact it before
exposing it.

## Provider concurrency

Several spawn calls in one parent turn are tool calls and can begin
concurrently. Actual model requests depend on provider instances:

- Calls sharing one built-in provider object serialize through that provider's
  transport.
- Give independent children distinct provider instances when their model calls
  must overlap.
- A typed Definition with its own model builds a provider for that worker; an
  inherited provider remains shared.

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
child's terminal entry makes later delivery a no-op.

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
