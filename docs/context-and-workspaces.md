# Context and workspaces

Mistri keeps several kinds of context separate so the host can give each one
the right lifetime and authority:

| Mechanism | Purpose | Source lifetime |
| --- | --- | --- |
| `system:` | Stable instructions for the Agent | Agent instance |
| `context:` | Host objects available to tool policy and handlers | Agent instance |
| `skills:` | Host-curated playbooks loaded by the model on demand | Host files or objects |
| `transform_context:` | Per-turn view of replay history | Agent instance |
| Session messages | Durable conversation and control facts | Session store |
| Workspace | Text the built-in document tools can edit | Workspace backend |
| `Mistri::Memory` | Host-owned knowledge shared across sessions | Host backend |

Any model-visible Skill, workspace, or memory tool call and result is still an
ordinary Session message. Reading external context can therefore copy that
content into the Session log.

Do not put credentials into prompts, Skills, or persisted messages. Pass
request-scoped identity and services through `context:` and authorize every tool
at its execution boundary.

## Skills

A Skill is a named playbook with a short description and a full Markdown body.
Only the descriptions join the system prompt. Mistri adds `read_skill`, and the
model requests a body when the current task needs it.

Load either `<root>/<name>/SKILL.md` directories or flat `<root>/<name>.md`
files:

```ruby
skills = Mistri::Skills.load("app/agent_skills")

agent = Mistri.agent(
  "claude-opus-4-8",
  skills: skills,
  tools: application_tools,
)
```

`skills:` also accepts the directory path directly. A Skill file may begin with
the deliberately small frontmatter contract:

```markdown
---
name: incident-review
description: Review an incident timeline for missing evidence and unsafe claims.
---

# Incident review

Read the timeline first. Separate observed facts from inference...
```

Only flat `name` and `description` string fields are interpreted. This is not a
general YAML configuration surface. Without frontmatter, the file or directory
name becomes the Skill name.

Skill bodies are instructions, not a security boundary. Load only host-reviewed
files, keep descriptions specific enough for correct selection, and let tool
authorization enforce what the model may actually do.

## Definitions

A Definition keeps an Agent's editable prompt and host vocabulary in one
Markdown file:

```markdown
---
role: Trip planner
model: claude-opus-4-8
tools:
  - search_flights
  - book_hotel
---

Plan the trip for {first_name}. Confirm constraints before booking.
```

Load and assemble it through a host registry:

```ruby
definition = Mistri::Definition.load("app/agents/trip_planner.md")
tools = definition.tool_names.map { |name| tool_registry.fetch(name) }

agent = Mistri.agent(
  definition.model,
  system: definition.render(first_name: traveler.first_name),
  tools: tools,
)
```

`render` raises when a placeholder has no value instead of leaking a literal
`{first_name}` into the prompt. A nil value renders as empty. `role`, `model`,
and `tools` have convenience readers; other frontmatter remains available
through `definition.config` for the host to interpret.

Mistri never resolves a tool name or arbitrary Definition key by itself. The
host registry is the authority that turns configuration into application code.

## Application context

Pass acting identity and request-scoped services through `context:`:

```ruby
agent = Mistri.agent(
  "claude-opus-4-8",
  tools: tools,
  context: { actor: current_user, tenant: current_tenant },
  before_tool: lambda { |call, tool_context|
    allowed = policy.allowed?(
      tool_context.app.fetch(:actor),
      call.name,
      call.arguments,
    )
    next if allowed

    "not authorized"
  },
)
```

Handlers that accept a second argument receive the same
`Mistri::ToolContext`; `context.app` is exactly the host value. This context is
not persisted. Rebuild it from current identity and policy before resuming a
persisted Session. Return a sanitized block reason from `before_tool`; an
unexpected hook exception is also reported to the model and Session, including
its class and message.

## Per-turn context transforms

`transform_context:` accepts one callable or an Array. Before every provider
request, each callable receives the replay Messages and returns the Messages
that request should see. The transformed view is not appended to the Session.

This seam supports host redaction, retrieval, and deliberate windowing, but it
is low-level. Preserve message order and every tool-call/result pair. A
provider will reject a history whose correlation facts were removed.

For periodic instruction reinforcement, use the built-in Reminder:

```ruby
reminder = Mistri::Reminder.every(
  3,
  "Stay within the approved catalog. Verify availability before claiming it.",
)

agent = Mistri.agent(
  "claude-opus-4-8",
  tools: tools,
  transform_context: reminder,
)
```

The reminder counts completed assistant turns, appears only in the provider
request when due, and never becomes a Session message. Pass `after:` when the
first reminder should use a different turn boundary.

## Workspaces and document tools

A workspace is a four-method port:

```ruby
read(path)             # String or nil
write(path, content)
delete(path)
list(prefix = nil)     # sorted path Strings
```

A backend may additionally claim atomic conditional writes:

```ruby
atomic_writes? # true
snapshot(path) # Mistri::Workspace::Snapshot or nil
compare_and_write(path, content, expected_revision:) # Snapshot
```

`Snapshot#revision` is an opaque, nonempty String of at most 256 bytes for those
exact content bytes; Snapshot owns frozen base-String copies of both values.
`expected_revision: nil` means create only and must conflict if the document
exists. A non-nil revision must match the latest Snapshot for that path. On
success, `compare_and_write` returns the content and revision actually committed
by storage. A conditional mismatch raises `Mistri::WorkspaceConflictError`
without writing.

`edit_file` retries only that conflict, at most three total attempts, and
reapplies the anchored replacement to each fresh snapshot. Concurrent changes
outside the target therefore survive; a target that no longer matches becomes
the ordinary actionable edit failure. Save, callback, validation, connection,
and other errors are never retried. If storage transforms the committed bytes,
the write is not retried or falsely reported as the exact requested
replacement: the model receives an error-marked result saying the write
committed and must read the document again. Custom four-method workspaces keep
their existing behavior unless they explicitly return true from
`atomic_writes?` and implement both methods.

Bind one to the built-in read, write, edit, find, and list tools:

```ruby
workspace = Mistri::Workspace::Memory.new
workspace.write("brief.md", "# Launch brief\n")

agent = Mistri.agent(
  "claude-opus-4-8",
  tools: Mistri::Tools.files(workspace),
  system: "Read before editing. Keep the brief concise.",
)
```

The tool names deliberately use the familiar file vocabulary even when the
backend is a database row or host callback.

### Memory workspace

`Mistri::Workspace::Memory` is a mutex-protected document map for tests and
ephemeral work. Its conditional writes are atomic between threads sharing the
instance. It is not durable across processes.

### Directory workspace

```ruby
workspace = Mistri::Workspace::Directory.new("tmp/agent-workspace")
```

Directory expands model paths under one canonical root, rejects lexical escape,
refuses traversal through existing file or directory symlinks, and omits
symlinked entries from listings. The host must keep the root and its tree stable
for the workspace instance's lifetime. This is not an operating-system sandbox
against a concurrent process changing filesystem entries, and Directory does
not claim atomic conditional writes. A correct cross-process implementation
needs a stable lock namespace and atomic replacement, not a Ruby mutex.

Use a dedicated root with host-owned permissions. Do not point model-controlled
tools at an application checkout, credential directory, or shared mutable tree.

### Single-value workspace

Wrap one host-owned value, such as a page draft or database column:

```ruby
workspace = Mistri::Workspace::Single.new(
  path: "page.html",
  read: -> { page.reload.draft_html },
  write: ->(html) { page.update!(draft_html: html) },
  synchronize: lambda do |&operation|
    if page.class.connection.transaction_open?
      raise Mistri::ConfigurationError, "page editor must run outside a transaction"
    end

    page.with_lock(&operation)
  end,
)
```

The value can be read and rewritten but not deleted. `synchronize:` is
optional; when supplied, Mistri performs the revision check and write inside
that host boundary, so `page.with_lock` makes anchored edits atomic across
application processes. The raw callbacks still own validation, authorization,
and any database normalization. Without `synchronize:`, Single retains the
legacy four-method behavior and makes no atomicity claim.

`synchronize:` is an executable host assertion, not merely a mutex callback:
it must cover the current read, conditional check, write, and committed read
across every writer that claims the same guarantee. For an Active Record value,
it must also refuse an already-open host transaction as above. Under MySQL's
repeatable-read default, joining an earlier transaction can make an ordinary
reload observe stale bytes even after a locking read.

### Active Record workspace

The optional adapter is not loaded by `require "mistri"`:

```ruby
require "mistri/workspace/active_record"

workspace = Mistri::Workspace::ActiveRecord.new(
  AgentDocument,
  scope: { tenant_id: current_tenant.id },
)
```

The host model needs a non-null primary key, non-null `path` and `content`
columns, non-null columns for every scope key, and a non-partial unique index
whose columns are exactly the scope plus `path`. Scope values must be singular
String, Symbol, Numeric, Boolean, Time, or Date equality values, not collections,
Ranges, subqueries, custom mutable objects, or nil. The adapter verifies the
model primary key against the database catalog and proves the remaining schema
facts before claiming atomic writes. It uses the host's Active Record
connection; Mistri does not require Rails or Active Record as a runtime
dependency. On PostgreSQL, and on MySQL2 or Trilogy when the table is InnoDB,
anchored edits use an exact-byte content revision, then a short transaction and
locking read before `save!`; validations and callbacks still run, and no
`lock_version` column is required. MyISAM and unrecognized storage engines, as
well as other adapters, retain the legacy four-method behavior rather than
advertise an unproved lock. Create-only conditional writes rely on the verified
unique scope/path index. The adapter copies and freezes the scope Hash plus
nested Hash, Array, Range, and String values at construction; atomic mode's
narrower scalar contract keeps its tenant identity stable.

Storage and schema capability are inspected once when the workspace is first
bound to a tool and then cached off the edit path. Keep that model on the same
database role and shard, and do not change its table or indexes during the
workspace's lifetime.

Unsupported storage deliberately keeps the adapter's legacy read/write behavior.
If lost-update protection is mandatory for your host, assert the capability at
boot instead of accepting that fallback:

```ruby
raise "workspace is not atomic" unless workspace.atomic_writes?
```

Build and run the Agent outside any host Active Record transaction. The adapter
rejects atomic snapshots and writes when its connection already has an open
transaction: joining it would let MySQL repeatable-read snapshots stay stale
across a retry and would extend Mistri's row lock to a boundary it does not own.

## Durable memory across sessions

`Mistri::Memory` is one replaceable text value stored wherever the host chooses:

```ruby
memory = Mistri::Memory.new(
  read: -> { organization.agent_memory.to_s },
  write: ->(text) { organization.update!(agent_memory: text) },
)

agent = Mistri.agent(
  "claude-opus-4-8",
  tools: Mistri::Tools.memory(memory),
)
```

The generated `read_memory` and `update_memory` tools make the model read the
current value and replace it as one coherent document. The host decides scope,
authorization, size, retention, and conflict handling. Expose only
`read_memory` when writes are not allowed; when a memory update requires human
approval, build an equivalent gated Tool around `Memory#replace`. The helper's
`update_memory` tool is ungated. Memory is not a hidden vector store. Its
backing value lives outside the Session, but `read_memory` copies the value into
a persisted tool result and `update_memory` persists the replacement text in
the tool call.

## Concurrency and delegation

Workspace thread safety is backend-defined. Memory supplies in-process atomic
writes; supported Active Record storage supplies scoped row-locking semantics;
Single does so only when `synchronize:` satisfies the contract above. Directory
and legacy custom workspaces do not turn host resources into transactions.
Blind writers that ignore the same database locking discipline can still
overwrite a later committed value; the host owns those external write paths and
authorization.

Sub-agent tools are ordinary Ruby objects and may close over a workspace. A
dispatcher therefore requires a host-owned runtime factory; the model has no
workspace selector. The factory receives the immutable dispatch spec and
constructs the provider, tools, and workspace inside the worker. Mistri
enforces the spec's exact tool-name grant, while the host remains responsible
for whether the reconstructed backend is fresh, shared, transactional, or
actually isolated. Derive durable workspace scope from trusted identifiers such
as the child Session ID, reopen that same scope on queue retry, and release
per-child resources through Runtime's `cleanup:` hook. See
[Sub-agents](sub-agents.md#execution-modes).

## Related guides

- [Tool contracts](tool-contracts.md)
- [Sessions and control](sessions.md)
- [Sub-agents](sub-agents.md)
- [Reliability](reliability.md)
- [Upgrading](../UPGRADING.md)
