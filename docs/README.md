# Mistri documentation

Mistri is an agent harness for Ruby applications. The
[project README](../README.md) is the shortest path from installation to a
working tool-using agent. This directory carries the contracts needed when the
agent becomes part of a real application.

## Start here

1. Run the [sixty-second example](../README.md#start-in-sixty-seconds).
2. Read [Tool contracts](tool-contracts.md) before connecting model output to
   application behavior.
3. Read [Sessions and control](sessions.md) before making a run durable or
   accepting approvals from another process.
4. Read [Reliability](reliability.md) before a tool performs external writes.
5. Check the [upgrade guide](../UPGRADING.md) before changing Mistri versions.

## Guides

| Guide | Use it when |
| --- | --- |
| [Tool contracts](tool-contracts.md) | Defining schemas, validating arguments, gating tools, returning UI data, or handing off a turn |
| [Sessions and control](sessions.md) | Choosing a store, resuming, steering, approving, compacting, or rendering transcripts |
| [Context and workspaces](context-and-workspaces.md) | Loading Skills and Definitions, transforming context, storing host-owned memory, or exposing editable documents |
| [Sub-agents](sub-agents.md) | Delegating into child sessions, dispatching background workers, or exposing worker controls |
| [MCP](mcp.md) | Connecting Streamable HTTP or stdio servers, OAuth, private networks, or large results |
| [Reliability](reliability.md) | Handling retries, events, budgets, response limits, cancellation, concurrency, and side effects |
| [Upgrade guide](../UPGRADING.md) | Moving an existing host between releases |
| [Changelog](../CHANGELOG.md) | Reading the exact history of every public behavior change |

## Common paths

### Add a durable conversation

Use [`Mistri::Session`](sessions.md#sessions) with a built-in store or a host
adapter. The store contract is two methods: `append(id, entry)` and `load(id)`.

### Put a human before a write

Declare `needs_approval:` on the tool, route the returned call ID to the human,
append the decision through a bare Session, and rebuild the current tools and
policy before calling `resume`. The complete flow is in
[Human approval](sessions.md#human-approval).

### Stream into a web response

Pass a block to `run`, or use `Mistri::Sinks::SSE` with any IO-like stream.
Action Cable is an optional sink, not a framework requirement. See
[Events and sinks](reliability.md#events-and-sinks).

### Connect an MCP server

Build `Mistri::MCP::Client` with exactly one of `url:` or `command:`, then turn
the remote tools into local tools with `Mistri::MCP.tools`. Start with
[MCP transports](mcp.md#transports).

### Run work in another agent

Use `Mistri::SubAgent` for a fixed specialist or `Mistri::SubAgent.pack` for a
host-bounded worker pool. Read the [execution modes](sub-agents.md#execution-modes)
before adding a queue dispatcher.

### Give the model editable context

Use Skills for on-demand playbooks, Definitions for host-assembled Agent
configuration, a Workspace for document tools, or `Mistri::Memory` for one
host-owned value shared across Sessions. The boundaries are in
[Context and workspaces](context-and-workspaces.md).

## Framework policy

The gem owns mechanism. The host application owns users, authorization,
business policy, queues, persistence schema, presentation, and the semantics of
external side effects. Optional adapters are provided for common Rails
components, but every core contract works without Rails.

## Source landmarks

- [`lib/mistri/agent.rb`](../lib/mistri/agent.rb) owns the run loop.
- [`lib/mistri/session.rb`](../lib/mistri/session.rb) owns the append-only replay
  and approval audit.
- [`lib/mistri/tool.rb`](../lib/mistri/tool.rb) and
  [`lib/mistri/schema.rb`](../lib/mistri/schema.rb) own tool contracts.
- [`lib/mistri/mcp/`](../lib/mistri/mcp) contains the MCP client and transports.

For contribution setup and quality gates, see
[`CONTRIBUTING.md`](../CONTRIBUTING.md).
