# Sessions and control

A session is Mistri's source of truth: an append-only sequence of typed JSON
entries. Messages, approvals, steering, compaction boundaries, child links, and
reports share that one record. Derived state is rebuilt from the log instead of
being repaired in place after a crash. Persistence strength belongs to the
chosen store.

## Sessions

Every Agent has a Session. Without one, Mistri creates an in-memory session:

```ruby
agent = Mistri.agent("claude-opus-5-5")
agent.session.id
```

Pass a persistent store when work must survive a process:

```ruby
store = Mistri::Stores::JSONL.new("tmp/mistri-sessions")
session = Mistri::Session.new(store: store)

agent = Mistri.agent("claude-opus-5-5", session: session)
agent.run("Start the research plan.")

reloaded = Mistri::Session.new(store: store, id: session.id)
Mistri.agent("claude-opus-5-5", session: reloaded).run("Continue the plan.")
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

The store must preserve each append as one entry, provide a stable total order
per session, and make a successful append visible to subsequent loads. Values
returned by `load` must not let caller mutation rewrite durable history: return
fresh decoded copies or deeply immutable snapshots. Mistri does not rely on
Ruby object identity. `Session#append` normalizes entries through JSON, so store
implementations see string keys and JSON values.

### Reading only what is new

A session that loads its whole log on every turn costs more as it ages. A
store lets a session read each entry once by answering two more things:

```ruby
load(session_id, from: 0) # the entries at position `from` and after
settled?                  # true when a load returns only committed entries
```

An entry's position is the number of entries appended before it, and it never
changes. While `settled?` is true, a `Session` object holds the entries it has
read, image data included, and asks only for the ones after them. When it is
false, or the store does not answer it, the session reads the whole log with
`load(session_id)` and holds nothing.

Answer true only when the load that follows returns committed entries that
can no longer change or disappear. Entries must also become visible in order:
a load never shows an entry before one that was appended earlier. On a
database, answer false while a transaction is open on the connection that
reads: its own rows can be rolled back, and it expects to read its own
snapshot. The answer has to hold for the load that follows it and for the
place that load reads from, so a subclass or a wrapper that reads from
somewhere else must answer for itself and not inherit the answer. When in
doubt answer false. A session then reads the whole log, which is always
correct. The built-in stores answer both.

Built-in stores are:

- `Mistri::Stores::Memory` for one process and tests;
- `Mistri::Stores::JSONL` for one file per session;
- `Mistri::Stores::ActiveRecord` for a host model and database.

JSONL names each file after the session id, so the id must match
`[A-Za-z0-9_-]{1,249}`; any other id raises `ArgumentError`. It creates each
file with mode 0600 and closes each append, so completed lines survive an
ordinary process restart. A partial last line left by a crash mid-write is
skipped on load and the next append starts on a fresh line. Load skips any
line it cannot parse, so it does not detect damage to a complete line. Every
load reads the whole file, whatever `from` is. It does not call `fsync`,
provide a database transaction, or promise power-loss durability. Use a
database or host store when either distinction matters.

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
independent writers, and it serves every read: a load from a position is one
range read on it. It also serves a read or a delete of a whole session, so the
store needs no other index.

Positions run 1, 2, 3 with no gap because rows are only ever appended. A read
whose rows are not at consecutive positions raises
`Mistri::ConfigurationError`, which is what deleting a row from the middle of
a session causes. Delete a session's rows together. The reading connection
needs READ COMMITTED or a stronger isolation level, which MySQL and PostgreSQL
have by default. The store knows about a transaction that Active Record
opened. One begun with raw SQL is invisible to it, so do not read a session
inside one.

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

The Session does not store the system prompt or the tool definitions. On
current Claude models a change to either makes the API drop the session's
earlier thinking. The run continues. See
[Thinking is signed against the prefix](reliability.md#thinking-is-signed-against-the-prefix).

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

Mistri tells the model about the gate. The description a provider receives
ends with "A person reviews each call before it runs.", or "may review a call"
for a predicate. Without it, a careful model asks the user in text and the run
never reaches the approval.

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
  "claude-opus-5-5",
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
log. A decision is single-assignment: the first valid decision in durable store
order wins, repeating that winning value is idempotent, and a conflicting caller
receives `Mistri::ConfigurationError`. Concurrent losing attempts can remain in
the raw append-only log, but they are inert and cannot revoke the winner or
corrupt the Session. The first note wins. Duplicate requests and malformed,
orphaned, or mismatched controls still fail closed.

Mistri does not implement quorum or denial precedence. Resolve multi-reviewer
policy in the host before recording its one final Session decision. A host that
must prevent losing attempts from reaching the raw log also needs to serialize
its decision endpoint; the two-method store contract reconciles concurrent
appends rather than conditionally preventing them.

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
instruction is answered. `steer` raises `ArgumentError` for text that is empty
or only whitespace.

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
  max_tokens: 8_192,
  fallback: "claude-sonnet-5-5",
  instructions: "Preserve decisions, identifiers, and unresolved risks.",
)

agent = Mistri.agent("claude-opus-5-5", compaction: settings)
```

An explicit `window:` enables compaction for an uncatalogued deployment. An
explicit `reserve:` is host policy; the automatic default otherwise protects a
catalogued model's shared output capacity plus framing slack. Gemini publishes
an independent input limit, so its automatic reserve remains input-oriented.

The summary is the compactor's own request. `max_tokens:` bounds its output
on every built-in provider (16,384 by default, never more than the model's
published output limit; sent as Anthropic `max_tokens`, OpenAI
`max_output_tokens`, and Gemini `maxOutputTokens`, each of which counts
thinking or reasoning toward the limit). The request runs with the API's
default thinking and reasoning, so a short limit, a thinking budget, or a
reasoning effort a host set for its own replies never shapes the summary.
Ordinary turns keep the host's settings.

`fallback:` names a second summarizer, a provider or a model id, that gets one
try when the session's provider cannot write a usable summary for any reason,
a refusal included. The model that failed is never asked again: a fallback
naming the primary's own model is skipped, so a second deployment of the same
model is not a fallback. The host chooses it, so a refusal never changes
models silently. Natural pairs are a smaller model of the same family: Sonnet
5.5 behind Fable 5.1 or Opus 5.5, Sol behind Astra, Flash behind Gemini Pro. The
compaction entry records which model wrote the summary, and the `:compaction`
event carries that reply in `event.message` (so a serialized event repeats the
summary once). When both fail, the one `compaction_failed` entry names each
model with its reason, and the usage of both attempts is counted. An attempt
that reports no usage counts as unknown cost. Under a cost budget an unpriced
attempt ends compaction before the fallback can spend, and the agent validates
the fallback's pricing at construction, so give a cost-budgeted agent an
explicitly configured provider with a deterministic service tier rather than
a model id.

```ruby
agent.context_usage
# => { tokens: 141_000, window: 1_000_000, fraction: 0.141 }

agent.compact
```

Manual `compact` returns nil when there is no useful cut. During a compaction,
`:compacting` announces that work began. The later `:compaction` event carries
the visible summary in `event.content`.

The summary is a handoff for the model that resumes: seven fixed sections,
goal and the requests that shaped the work in the user's words, constraints,
exact facts and references, decisions, progress, open failures, and current
work with the next step. The summarizer records what each party said as
theirs, keeps current values only, and stays under a thousand words; later
checkpoints fold new messages into the previous summary under the same
headings. Replay introduces the result as a handoff written by another model
from the compacted messages, followed by the kept recent turns.

Only a normally completed summary with nonblank text and no tool calls can
become a checkpoint. A truncated or otherwise incomplete response leaves the
previous summary and retained context unchanged, emits `:compaction_failed`
with the reason in `event.error_message`, and appends a `compaction_failed`
entry carrying the reason and its trigger (`manual` or `automatic`), so the
failure shows in `entries` and `transcript` and survives an agent rebuilt in
another process. Manual `compact` raises `Mistri::CompactionError` with the
attempt's usage in `error.usage`. Automatic compaction counts that usage
toward the run and its budget, then continues with the existing context if
the budget permits. It tries again on a later turn while the context stays
over the threshold, and stops after three failed automatic attempts in a row
until a compaction succeeds; manual attempts are recorded but do not count.
If the context no longer fits, the next request can still fail with a
provider context-limit error.

The summary and kept-tail boundary append to the session. Provider replay then
uses the visible summary plus the retained tail, while the full original log
remains available through `entries` and `transcript`. Compaction cannot hide an
open approval or split a completed tool call from its result.

Current Claude models bind thinking to the conversation prefix. After
compaction, replay omits their pre-compaction thinking from the kept tail; new
thinking and the durable transcript stay intact. This applies to every
Anthropic model except the older ones the catalog names, so a model newer than
the catalog is covered. Other providers' thinking is unchanged. Manual
compaction must use the same per-session serialization as `run` and `resume`,
between provider turns, not inside an event callback or alongside an in-flight
request. An answer generated against the old prefix cannot safely join the
new one.

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
