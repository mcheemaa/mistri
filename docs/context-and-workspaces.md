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
ephemeral work. It is not durable across processes.

### Directory workspace

```ruby
workspace = Mistri::Workspace::Directory.new("tmp/agent-workspace")
```

Directory expands model paths under one canonical root, rejects lexical escape,
refuses traversal through existing file or directory symlinks, and omits
symlinked entries from listings. The host must keep the root and its tree stable
for the workspace instance's lifetime. This is not an operating-system sandbox
against a concurrent process changing filesystem entries.

Use a dedicated root with host-owned permissions. Do not point model-controlled
tools at an application checkout, credential directory, or shared mutable tree.

### Single-value workspace

Wrap one host-owned value, such as a page draft or database column:

```ruby
workspace = Mistri::Workspace::Single.new(
  path: "page.html",
  read: -> { page.reload.draft_html },
  write: ->(html) { page.update!(draft_html: html) },
)
```

The value can be read and rewritten but not deleted. The callback owns
transactions, optimistic locking, validation, and authorization.

### Active Record workspace

The optional adapter is not loaded by `require "mistri"`:

```ruby
require "mistri/workspace/active_record"

workspace = Mistri::Workspace::ActiveRecord.new(
  AgentDocument,
  scope: { tenant_id: current_tenant.id },
)
```

The host model needs `path` and `content` columns and a unique index covering
the scope plus `path`. The adapter uses the host's Active Record connection;
Mistri does not require Rails or Active Record as a runtime dependency.

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

Workspace thread safety is backend-defined. Memory synchronizes its map;
Directory and Single do not turn host resources into transactions. Active
Record supplies database operations, but the host still owns isolation and
conflict policy.

Sub-agent tools are ordinary Ruby objects and may close over a workspace. A
background worker's `workspace: "own"` declaration does not clone those
objects. Reconstruct isolated tool and workspace instances in a production
dispatcher before allowing parent and child work to overlap. See
[Sub-agents](sub-agents.md#execution-modes).

## Related guides

- [Tool contracts](tool-contracts.md)
- [Sessions and control](sessions.md)
- [Sub-agents](sub-agents.md)
- [Reliability](reliability.md)
- [Upgrading](../UPGRADING.md)
