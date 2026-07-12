<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="مستری" width="360">
  </picture>
</p>

<p align="center"><strong>mistri</strong>, the agent harness for Ruby applications.</p>

<p align="center"><a href="https://mistri.sh">mistri.sh</a> · <a href="docs/README.md">documentation</a> · <a href="UPGRADING.md">upgrading</a></p>

<p align="center">
  <a href="https://rubygems.org/gems/mistri"><img alt="Gem Version" src="https://img.shields.io/gem/v/mistri"></a>
  <a href="https://github.com/mcheemaa/mistri/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mcheemaa/mistri/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://codecov.io/gh/mcheemaa/mistri"><img alt="Coverage" src="https://img.shields.io/codecov/c/github/mcheemaa/mistri"></a>
  <a href="mistri.gemspec"><img alt="Ruby >= 3.2" src="https://img.shields.io/badge/ruby-%3E%3D%203.2-CC342D"></a>
  <a href="mistri.gemspec"><img alt="Runtime dependencies: zero" src="https://img.shields.io/badge/runtime_deps-0-brightgreen"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

A mistri (Urdu: مستری) is the fixer: the skilled tradesperson who actually
gets it done. Mistri is an application-embedded agent runtime for Ruby. It owns
the model loop, safe tool boundary, event stream, and append-only session
record. Your application owns authorization, policy, presentation, and the
semantics of its side effects.

Mistri works in plain Ruby applications, including Rails, Sinatra, Hanami, jobs,
and services. Rails integrations are optional. The gem declares zero runtime
dependencies.

## Start in sixty seconds

Add Mistri to your bundle:

```ruby
gem "mistri"
```

Then define a tool and run an agent:

```ruby
require "mistri"

weather = Mistri::Tool.define(
  "get_weather", "Current weather for a city.",
  schema: -> { string :city, "City name", required: true },
) do |args|
  { city: args.fetch("city"), forecast: "34 C and clear" }
end

agent = Mistri.agent("claude-opus-4-8", tools: [weather])

result = agent.run("What should I wear in Lahore today? One sentence.") do |event|
  print event.delta if event.type == :text_delta
end
puts
```

`Mistri.agent` infers the provider from the model ID and reads
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `GEMINI_API_KEY`. Pass `api_key:`
explicitly when the host resolves credentials another way. A normally
completed invocation returns a `Mistri::Result` with status
predicates, final text, usage, and structured task output when requested.
Host-contract failures raise as documented in [Reliability](docs/reliability.md).

Runnable examples live in [`examples/`](examples).

## Why Mistri

- **One session model.** The same append-only log runs over memory, JSONL,
  Active Record, or a host store. With a persistent store, runs can suspend,
  reload, resume, steer, and compact without inventing a second state model. See
  [Sessions and control](docs/sessions.md).
- **Human approval does not hold a thread.** A gated tool parks the request and
  returns. With a shared store, another process can record the decision later;
  `resume` revalidates the exact call before execution.
- **Provider semantics survive the abstraction.** Anthropic, OpenAI, and
  Gemini stream through direct implementations that retain each provider's
  reasoning, tool-pairing, and replay requirements. Unknown model IDs still
  pass through when their provider can be inferred.
- **Tool input crosses a real boundary.** Completed model arguments are owned,
  bounded, validated, and deeply frozen before hooks, approval predicates, MCP,
  or handlers see them. See [Tool contracts](docs/tool-contracts.md).
- **The runtime stays small.** The [gemspec](mistri.gemspec) declares no runtime
  gem dependencies. Optional Rails adapters load only when required.
- **Real APIs are part of the test strategy.** The
  [live integration suite](CONTRIBUTING.md#setup)
  exercises critical control, persistence, delegation, MCP, and
  structured-output paths across all three providers when their keys are
  present. The default CI suite remains hermetic.

## Choose the right layer

These projects solve different problems:

| Need | Start with |
| --- | --- |
| A durable tool loop inside any Ruby application, with append-only sessions, approval, steering, compaction, linked workers, and provider-neutral MCP | **Mistri** |
| Broad model access plus media, embeddings, image generation, and Rails-backed chat | [RubyLLM](https://github.com/crmne/ruby_llm) |
| Agents expressed through Rails controllers, actions, callbacks, views, and Active Job | [Active Agent](https://github.com/activeagents/activeagent) |

Mistri is deliberately not a terminal UI, hosted agent service, broad media
client, policy engine, or exactly-once job system. The host application keeps
its users, authorization rules, queues, database, UI, idempotency keys, and
reconciliation policy. Mistri supplies the execution mechanism that connects
them.

## How the loop works

1. The input is appended to the session before the provider is called.
2. Provider events stream to the subscriber as the response arrives.
3. Completed tool calls cross Mistri's ownership and validation boundary.
4. Current host policy and approval rules run before a handler can start.
5. Tool results append to the same session, then the model continues until it
   answers, hands off the turn, suspends for approval, aborts, or reaches a
   budget.

Every completed message is appended to the chosen Session store before the next
model-visible turn. Opaque reasoning and pairing metadata replay only to the
provider that created them; the shared transcript stays provider-neutral.

## Tools and approval

A tool has a name, description, JSON Schema object, and handler. Independent
calls in one model turn execute concurrently up to `max_concurrency`.

```ruby
book_hotel = Mistri::Tool.define(
  "book_hotel", "Books the selected hotel.",
  schema: lambda {
    string :hotel_id, "Hotel ID", required: true
    number :total_usd, "Quoted total", required: true
  },
  needs_approval: ->(args) { args.fetch("total_usd") > 500 },
) do |args, context|
  Bookings.create!(
    hotel_id: args.fetch("hotel_id"),
    traveler: context.app.fetch(:traveler),
  )
end

agent = Mistri.agent(
  "claude-opus-4-8",
  tools: [book_hotel],
  context: { traveler: current_traveler },
)
```

Validation runs before the approval predicate, so policy never receives a
string where the schema promised a number. Invalid calls return a bounded,
model-readable error and valid siblings still run. Mistri never coerces model
input implicitly.

When a gated call arrives:

```ruby
result = agent.run("Book the corner suite for the Lisbon trip")
result.awaiting_approval? # => true; the handler did not run

call = result.pending.fetch(0)
agent.session.approve(call.id, note: "Approved by finance")
result = agent.resume
```

That is the smallest in-process flow. With a durable store, a controller,
route, mutation, job, or console can append the decision using only the Session
ID and call ID; a later process rebuilds current tools and policy before
resuming. See [Sessions and control](docs/sessions.md#human-approval).

Tool results can also carry host-only UI data or an explicit failure fact. See
[Tool contracts](docs/tool-contracts.md) for schemas, validators, normalizers,
`Mistri::ToolResult`, hooks, and `ends_turn`.

## Sessions and control

The default memory store is useful for one process. JSONL persists the complete
append-only record on local disk without a database:

```ruby
store = Mistri::Stores::JSONL.new("tmp/mistri-sessions")
session = Mistri::Session.new(store: store)

agent = Mistri.agent("claude-opus-4-8", session: session)
agent.run("Start a haiku about the sea.")

# A later process can reload the same session by ID.
reloaded = Mistri::Session.new(store: store, id: session.id)
Mistri.agent("claude-opus-4-8", session: reloaded).run("Now finish it.")
```

For a database-backed store, implement `append(id, entry)` and `load(id)`, or
use the optional Active Record adapter:

```console
$ bin/rails generate mistri:install AgentEntry
```

```ruby
require "mistri/stores/active_record"

store = Mistri::Stores::ActiveRecord.new(AgentEntry)
```

Steering is another append, so a request handler or worker can redirect a live
exchange without sharing its Agent object:

```ruby
Mistri::Session.new(store: store, id: session_id).steer(
  "Make the headline blue instead."
)
```

Only one Agent may actively call `run` or `resume` for a session at a time.
Approvals, steering, and worker reports may append concurrently. Read the
[reliability contract](docs/reliability.md) before connecting tools with
external side effects.

## Streaming into any Ruby application

Every run accepts a block. Handle events directly, or compose a sink:

```ruby
sse = Mistri::Sinks::SSE.new(stream)          # any IO-like object
sink = Mistri::Sinks::Coalesced.new(sse)      # merge token bursts to UI speed

agent.run(input, &sink)
```

`Mistri::Sinks::ActionCable` is available for Rails, but no Railtie is required.
The same event stream works in Sinatra, Rack, a WebSocket server, a background
job, or a test. Event types form an extensible union; consumers should handle
the types they use and ignore the rest.

## Long conversations and structured tasks

Compaction is on by default for catalogued models. When a session enters the
model's safe headroom, Mistri asks the provider for a visible structured
summary, appends it, and continues from the summary plus a recent tail. The
exact history remains in the store for transcripts.

```ruby
agent.context_usage
# => { tokens: 141_000, window: 1_000_000, fraction: 0.141 }

agent.compact # explicit checkpoint; returns nil when nothing should compact
```

Task mode requires a final JSON value matching a schema. Providers use native
constraints only when they can represent the contract; Mistri validates the
answer locally in every case.

```ruby
schema = {
  type: "object",
  properties: {
    "tiers" => { type: "array", items: { type: "string" } },
  },
  required: ["tiers"],
}

result = agent.task("Extract the pricing tiers.", schema: schema)
result.output # parsed and validated
```

Task validation applies when that invocation completes normally. An approval
suspension or `ends_turn` handoff returns with `output` nil; after settlement or
the human answer, call `task` again if structured output is still required.

See [Sessions and control](docs/sessions.md) for compaction boundaries,
cross-provider replay, stores, approvals, and transcripts.

## Sub-agents

Delegate work into a child session so exploration does not consume the parent's
context. Only the report returns to the parent, while the full child transcript
remains linked and inspectable.

```ruby
researcher = Mistri::SubAgent.new(
  name: "researcher",
  description: "Reads pages and answers factual questions.",
  provider: Mistri.provider("claude-haiku-4-5"),
  system: "Research the question. Return findings and sources.",
  tools: [fetch_page],
)

agent = Mistri.agent("claude-opus-4-8", tools: [researcher.tool])
```

Mistri also provides a host-bounded spawn tool, named worker types, background
dispatch with worker-side runtime reconstruction, exact capability grants,
reports, steering, stopping, and a management console. See
[Sub-agents](docs/sub-agents.md), including the runtime, concurrency, and lease
limits a production dispatcher must understand.

## Model Context Protocol

Bridge tools over Streamable HTTP or stdio, then apply the same local approval
and validation boundary:

```ruby
client = Mistri::MCP::Client.new(
  url: "https://mcp.linear.app/mcp",
  token: -> { connection.bearer_token },
)

tools = Mistri::MCP.tools(
  client,
  prefix: "linear",
  gates: { "create_issue" => true },
)
```

Remote URLs default to public HTTPS with validated, pinned DNS answers. Inbound
records are size-bounded. An unconfirmed `tools/call` is never replayed
automatically because the server may already have committed its side effect.
OAuth services are storage-agnostic; the Rails connection generator is one
optional host adapter.

Read [MCP](docs/mcp.md) for stdio, OAuth, private-network policy, schema
authority, response limits, and large-result resource links.

## Skills, definitions, and workspaces

- **Skills** expose one-line descriptions until the model requests the full
  `SKILL.md`, keeping the system prompt small.
- **Definitions** load an agent's model, tool names, and prompt from Markdown
  with YAML frontmatter and checked placeholders.
- **Workspaces** give the built-in read, write, edit, find, and list tools a
  directory, memory value, Active Record table, or single host-owned value.

The edit engine refuses ambiguous matches. A Directory workspace rejects
lexical escape and traversal through existing symlinks in a stable,
host-controlled tree; it is not an operating-system sandbox. See
[Context and workspaces](docs/context-and-workspaces.md) and the runnable
[`page_editor.rb`](examples/page_editor.rb) example.

## Reliability contract

Mistri makes failures explicit, but it does not pretend distributed side
effects are exactly once:

- Provider requests retry transient failures with backoff. The MCP client never
  replays an ambiguous tool call; the Agent bridge returns the uncertainty as
  an error-marked tool result.
- A process can crash after a handler commits an external write but before the
  result reaches the session. Tools with side effects must be idempotent or
  reconcilable.
- Budgets are checked between model-visible turns, so they are soft ceilings.
- Provider and MCP records default to an 8 MiB per-record limit; streaming has
  no total-size limit while each record remains safe.
- `Mistri::AbortSignal` is an in-process cooperative signal. Cross-process
  worker control uses the configured lock adapter and is also cooperative.

The complete operational contract, event lifecycle, retry behavior, pricing
rules, and sink guidance live in [Reliability](docs/reliability.md).

## Documentation

All primary documentation is versioned with the code and renders directly on
GitHub:

| Guide | What it covers |
| --- | --- |
| [Documentation index](docs/README.md) | The complete task-oriented map |
| [Tool contracts](docs/tool-contracts.md) | Schemas, validation, approval, hooks, results, and handoff |
| [Sessions and control](docs/sessions.md) | Stores, replay, approvals, steering, compaction, and transcripts |
| [Context and workspaces](docs/context-and-workspaces.md) | Skills, definitions, context transforms, host-owned memory, and editable documents |
| [Sub-agents](docs/sub-agents.md) | Specialists, spawning, dispatch, locks, reports, and control |
| [MCP](docs/mcp.md) | HTTP and stdio, OAuth, egress policy, limits, and schema handling |
| [Reliability](docs/reliability.md) | Retries, events, budgets, stopping, concurrency, and side effects |
| [Upgrade guide](UPGRADING.md) | Required host changes between releases |
| [Changelog](CHANGELOG.md) | Complete release history and exact behavior changes |

## Testing and contributing

The default suite is hermetic and needs no API keys:

```console
$ bundle exec rake test
$ bundle exec rubocop
```

Live tests read provider keys from the gitignored
`.env.development.local` file:

```console
$ MISTRI_LIVE=1 bundle exec rake test
$ bundle exec rake integration
$ MISTRI_INTEGRATION_MODELS=claude-opus-4-8 bundle exec rake integration
```

The integration matrix exercises critical end-to-end scenarios against one
Anthropic, OpenAI, and Gemini model by default when the corresponding keys are
present. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the project contract.

## Compatibility and support

Mistri supports Ruby 3.2 and newer. It is pre-1.0: minor releases may include
intentional contract changes with an explicit migration path. Read
[UPGRADING.md](UPGRADING.md) and [CHANGELOG.md](CHANGELOG.md) before upgrading.

Use [GitHub issues](https://github.com/mcheemaa/mistri/issues) for reproducible
bugs and focused feature proposals. Report vulnerabilities privately as
described in [SECURITY.md](SECURITY.md).

## Credits

Mistri's architecture is informed by [pi](https://github.com/badlogic/pi-mono)
by Mario Zechner. See [NOTICE](NOTICE).

## License

MIT. See [LICENSE](LICENSE).
