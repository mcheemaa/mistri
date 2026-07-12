# Sessions and control

A session is Mistri's source of truth: an append-only sequence of typed JSON
entries. Messages, approvals, steering, compaction boundaries, child links, and
reports share that one record. Derived state is rebuilt from the log instead of
being repaired in place after a crash. Persistence strength belongs to the
chosen store.

## Sessions

Every Agent has a Session. Without one, Mistri creates an in-memory session:

```ruby
agent = Mistri.agent("claude-opus-4-8")
agent.session.id
```

Pass a persistent store when work must survive a process:

```ruby
store = Mistri::Stores::JSONL.new("tmp/mistri-sessions")
session = Mistri::Session.new(store: store)

agent = Mistri.agent("claude-opus-4-8", session: session)
agent.run("Start the research plan.")

reloaded = Mistri::Session.new(store: store, id: session.id)
Mistri.agent("claude-opus-4-8", session: reloaded).run("Continue the plan.")
```

`Session#entries` returns the raw typed log. `Session#messages` returns the
provider-neutral conversation after replay and compaction. `Session#transcript`
returns a presentation-oriented entry view with inline image bytes removed. It
is not an authorization or redaction boundary: prompts, tool arguments and
results, UI payloads, errors, and provider metadata can remain. Authorize and
redact before exposing a transcript.

Mistri does not encrypt JSONL or Active Record session payloads. The host owns
storage encryption, access control, retention, deletion, and redaction specific
to the application. Treat the complete session record as sensitive data.

## Store contract

A store implements:

```ruby
append(session_id, entry_hash) # append one JSON-shaped entry
load(session_id)               # return entries in append order
```

The store must preserve each append as one entry and provide a total order per
session. Values returned by `load` must not let caller mutation rewrite durable
history: return fresh decoded copies or deeply immutable snapshots. Mistri does
not rely on Ruby object identity. `Session#append` normalizes entries through
JSON, so store implementations see string keys and JSON values.

Built-in stores are:

- `Mistri::Stores::Memory` for one process and tests;
- `Mistri::Stores::JSONL` for one file per session;
- `Mistri::Stores::ActiveRecord` for a host model and database.

JSONL closes each append, so completed lines survive an ordinary process
restart. It does not call `fsync`, provide a database transaction, or promise
power-loss durability. Use a database or host store when that distinction
matters.

### Active Record

The adapter is opt-in and Mistri never requires Rails at boot:

```ruby
require "mistri/stores/active_record"

store = Mistri::Stores::ActiveRecord.new(AgentEntry)
```

Generate a host-named model and migration in Rails:

```console
$ bin/rails generate mistri:install AgentEntry
```

The table needs `session_id`, `position`, and `payload`, plus a unique index on
`[session_id, position]`. The unique index is the optimistic append boundary for
independent writers.

On MySQL and Trilogy, `payload` must be LONGTEXT because one legal parallel
tool turn can exceed MEDIUMTEXT even while each call stays inside its own
limit. New migrations use `size: :long`. Existing tables need a host migration:

```ruby
change_column :agent_entries, :payload, :text, size: :long, null: false
```

PostgreSQL `text` does not need that change.

## Run and resume

`run` appends a new user input and advances the model loop. Do not call it while
the session has open approvals; use `resume`.

`resume` does not append user text. It audits open approval state, returns
immediately if a decision is still missing, settles decided calls, and then
continues the existing exchange.

Rebuild the Agent with the current tool definitions, authorization context,
hooks, provider configuration, and business policy before resuming. The Session
contains durable facts, not frozen application policy.

## Human approval

Declare a boolean or argument predicate on the tool:

```ruby
send_gift = Mistri::Tool.define(
  "send_gift", "Sends a physical gift.",
  schema: lambda {
    string :recipient_id, "Recipient ID", required: true
    number :value_usd, "Gift value", required: true
  },
  needs_approval: ->(args) { args.fetch("value_usd") > 100 },
) do |args|
  Gifts.send!(
    recipient_id: args.fetch("recipient_id"),
    value_usd: args.fetch("value_usd"),
  )
end
```

When the model calls it:

```ruby
result = agent.run("Send the launch gift to customer 42")
result.awaiting_approval? # => true

call = result.pending.first
session_id = agent.session.id
```

The handler has not run. Persist or route `session_id` and `call.id` in the
host's own UI. A decision needs only a store and Session:

```ruby
session = Mistri::Session.new(store: store, id: session_id)
session.approve(call.id, note: "Approved by finance")
# or: session.deny(call.id, note: "Use the standard gift instead")
```

The decision may be appended from another process at any later time. Nothing
sleeps while waiting. To continue:

```ruby
session = Mistri::Session.new(store: store, id: session_id)
agent = Mistri.agent(
  "claude-opus-4-8",
  tools: current_tools,
  session: session,
  context: current_authorization_context,
  before_tool: current_policy,
)

result = agent.resume
```

Approved arguments are the exact prepared value the human reviewed. Resume
verifies their source and pairing metadata, revalidates them against the current
schema, and runs `before_tool` again. It does not renormalize or reevaluate the
approval predicate.

`Session#open_approvals` derives every still-open call and its decision from the
log. Duplicate, late, malformed, or mismatched control entries fail closed.

Denial is returned to the model as an expected result so it can choose another
path. It is not marked as a tool execution error.

## Steering and the inbox

Steering queues a user message for the next turn boundary:

```ruby
Mistri::Session.new(store: store, id: session_id).steer(
  "Focus only on contracts renewed this quarter."
)
```

The active Agent does not need to be shared with the writer. If a steer lands
while the model finishes cleanly, the run extends for another turn so the new
instruction is answered.

Background child reports use the same ordered inbox. A host that wakes idle
sessions should watch `session.pending_inbox`, not only
`session.pending_steers`, so worker reports receive the same treatment.

Inbox consumption is itself an append: the folded message records the source
entry ID. A crash cannot consume a steer invisibly or require a repair write.

## Compaction

For a catalogued model, automatic compaction begins when estimated context use
crosses the published window minus safe output headroom. Disable it with
`compaction: false`, or pass policy explicitly:

```ruby
settings = Mistri::Compaction.new(
  reserve: 64_000,
  keep_recent: 24_000,
  instructions: "Preserve decisions, identifiers, and unresolved risks.",
)

agent = Mistri.agent("claude-opus-4-8", compaction: settings)
```

An explicit `window:` enables compaction for an uncatalogued deployment. An
explicit `reserve:` is host policy; the automatic default otherwise protects a
catalogued model's shared output capacity plus framing slack. Gemini publishes
an independent input limit, so its automatic reserve remains input-oriented.

```ruby
agent.context_usage
# => { tokens: 141_000, window: 1_000_000, fraction: 0.141 }

agent.compact
```

Manual `compact` returns nil when there is no useful cut. During a compaction,
`:compacting` announces that work began. The later `:compaction` event carries
the visible summary in `event.content`.

The summary and kept-tail boundary append to the session. Provider replay then
uses the visible summary plus the retained tail, while the full original log
remains available through `entries` and `transcript`. Compaction cannot hide an
open approval or split a completed tool call from its result.

Very large tool results may be shortened only in the request sent to the
summarizer. The durable result and ordinary replay remain unchanged until a
successful compaction intentionally replaces earlier context with the summary.

## Provider changes

The shared message model permits a session to continue with another built-in
provider. Opaque reasoning, signatures, and pairing metadata replay only to the
provider that created them.

Completed foreign tool exchanges become a neutral representation when needed.
In particular, Mistri does not manufacture a signed Gemini function call from
another provider's metadata.

Changing providers can alter model behavior even when replay is valid. Treat it
as explicit host policy, not transparent failover.

## Transcripts and child sessions

```ruby
session.transcript
session.transcript(include_children: true)
```

With `include_children: true`, each child transcript is spliced after its link
entry. Entries carry the same origin labels used by live events, so a reloaded
UI can reconstruct parent and worker lanes. See [Sub-agents](sub-agents.md).

## Concurrency and crashes

Independent appenders such as approvals, steering, and child reports are part
of the design. Active execution is different: only one Agent may call `run` or
`resume` for a session at a time.

Mistri persists each completed message promptly, but a process can still fail
after a handler starts or commits an external write and before its result is
durable. Replay heals an unanswered call with an interrupted error so the
provider history remains pairable. That error explicitly says the tool may
have run; it does not make replay safe.

Hosts must serialize active runners and make side effects idempotent or
reconcilable. Read [Reliability](reliability.md) for the complete contract.

## Related guides

- [Tool contracts](tool-contracts.md)
- [Sub-agents](sub-agents.md)
- [Reliability](reliability.md)
- [Upgrading](../UPGRADING.md)
