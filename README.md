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

Mistri runs AI agents inside your own Ruby application, on your models, your
database, your authorization, and your queue. A run can stop and wait for a
human to approve a tool call, then finish hours later in a different process.
The gem declares zero runtime dependencies.

A mistri (Urdu: مستری) is the fixer: the skilled tradesperson who actually
gets it done. Mistri works in plain Ruby, Rails, Sinatra, Hanami, jobs, and
services.

<p align="center">
  <img src="assets/vendors/claude-mark.svg" height="30" alt="Claude">&nbsp;&nbsp;&nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/vendors/openai-mark-dark.svg">
    <img src="assets/vendors/openai-mark.svg" height="30" alt="OpenAI">
  </picture>&nbsp;&nbsp;&nbsp;&nbsp;
  <img src="assets/vendors/gemini-mark.svg" height="30" alt="Gemini">
</p>

<p align="center">Anthropic, OpenAI, and Gemini, each through its own native protocol.</p>

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

agent = Mistri.agent("claude-opus-5", tools: [weather])

result = agent.run("What should I wear in Lahore today? One sentence.") do |event|
  print event.delta if event.type == :text_delta
end
puts
```

`Mistri.agent` infers the provider from the model ID and reads
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `GEMINI_API_KEY`. Runnable examples
live in [`examples/`](examples).

## Watch a run happen

```ruby
Mistri.logger = Rails.logger   # or any Logger-compatible object
```

```text
[mistri 0a1b2c3d] run "What is 2 plus 3?" (gpt-5.6, 3 tools)
[mistri 0a1b2c3d] turn 1 done tool_use (312 in / 48 out)
[mistri 0a1b2c3d] tool add#7f3a {"a":2,"b":3}
[mistri 0a1b2c3d] tool add#7f3a ok 12ms "5"
[mistri 0a1b2c3d] text "The sum is 5."
[mistri 0a1b2c3d] turn 2 done stop (410 in / 22 out)
[mistri 0a1b2c3d] done completed in 1.2s, 2 turns, 722 in / 70 out, $0.0042
```

One assignment, and every run tells its story in your ordinary log: inputs,
tools, durations, tokens, and dollar cost whenever pricing is known. Ship
those lines to your log platform and you have agent observability without a
dashboard. `content: false` keeps the story as metadata when payloads must
stay out. See [Logging](docs/logging.md).

## Pause for a human

A tool can require approval. The run parks the call and returns immediately;
no thread waits for the decision.

```ruby
send_gift = Mistri::Tool.define(
  "send_gift", "Sends the selected gift.",
  schema: -> { number :total_usd, "Quoted total", required: true },
  needs_approval: ->(args) { args.fetch("total_usd") > 500 },
) { |args| Gifts.send!(args) }

agent = Mistri.agent("claude-opus-5", tools: [send_gift])

result = agent.run("Send the executive box to Sarah.")
result.awaiting_approval? # => true; the handler did not run

call = result.pending.fetch(0)
agent.session.approve(call.id, note: "Approved by finance")
agent.resume
```

With a durable store, the decision can come from a controller, a job, or a
console in a different process, days later, using only the session ID and the
call ID. A later process builds a fresh Agent with its current tools and
policy; `resume` then revalidates the exact call and carries on. See
[Sessions and control](docs/sessions.md#human-approval).

## Why Mistri

- **Pause for a human, resume days later.** A gated call parks and the run
  returns; any process can record the decision and resume.
- **One durable session model.** The same append-only log runs over memory,
  JSONL, Active Record, or your own store: reload, resume, steer, and
  compact without a second state model.
- **Three providers, no lowest common denominator.** Anthropic, OpenAI, and
  Gemini keep their own reasoning, tool-pairing, and replay rules.
- **Tools cross a real boundary.** Model arguments are validated and frozen
  before your policy or handlers see them; invalid calls fail loudly.
- **Your Gemfile.lock grows by one line.** Zero runtime gem dependencies;
  Rails adapters load only when required.
- **Tested against the real APIs.** The live suite runs the control,
  persistence, delegation, MCP, and structured-output paths against actual
  Anthropic, OpenAI, and Gemini endpoints; the default CI suite is hermetic.

## Choose the right layer

These projects solve different problems:

| Need | Start with |
| --- | --- |
| A durable, approvable agent loop inside an existing Ruby application | **Mistri** |
| Broad model access plus media, embeddings, image generation, and Rails-backed chat | [RubyLLM](https://github.com/crmne/ruby_llm) |
| Agents expressed through Rails controllers, actions, callbacks, views, and Active Job | [Active Agent](https://github.com/activeagents/activeagent) |

Mistri is deliberately not a terminal UI, hosted agent service, media client,
or job system. It owns the model loop, the tool boundary, the event stream,
and the session record; your application owns authorization, policy,
presentation, and the meaning of its side effects.

## Sessions, steering, and stores

Sessions persist every message as it completes, so a crash or an abort leaves
a resumable record with no repair step. Any process can append to a live
session:

```ruby
store = Mistri::Stores::JSONL.new("tmp/mistri-sessions")
session = Mistri::Session.new(store: store)

Mistri.agent("claude-opus-5", session: session).run("Start a haiku about the sea.")

# A later process reloads the same session by ID and continues it.
reloaded = Mistri::Session.new(store: store, id: session.id)
Mistri.agent("claude-opus-5", session: reloaded).run("Now finish it.")

# Steering queues a redirect from anywhere, without the Agent object; a
# run in flight folds it at its next turn.
reloaded.steer("Make it about the mountains instead.")
```

For a database-backed store, run `bin/rails generate mistri:install AgentEntry`
and use the Active Record adapter, or implement `append(id, entry)` and
`load(id)` on anything. Only one Agent may run a session at a time; approvals,
steering, and worker reports may append concurrently. See
[Sessions and control](docs/sessions.md).

## Streaming into any Ruby application

Every run accepts a block. Handle events directly, or compose a sink:

```ruby
sse = Mistri::Sinks::SSE.new(stream)          # any IO-like object
sink = Mistri::Sinks::Coalesced.new(sse)      # merge token bursts to UI speed

agent.run(input, &sink)
```

`Mistri::Sinks::ActionCable` is available for Rails, but no Railtie is
required. The same event stream works in Sinatra, Rack, a WebSocket server, a
background job, or a test.

## Long conversations and structured tasks

Compaction is on by default for models with a known context window: near the
limit, Mistri asks the provider for a visible summary and continues from it,
while the exact history stays in the store. Task mode requires a final JSON
value matching a schema, validated locally whenever the run completes
normally.

```ruby
agent.context_usage
# => { tokens: 141_000, window: 1_000_000, fraction: 0.141 }

schema = {
  type: "object",
  properties: { "tiers" => { type: "array", items: { type: "string" } } },
  required: ["tiers"],
}

result = agent.task("Extract the pricing tiers.", schema: schema)
result.output # parsed and validated
```

See [Sessions and control](docs/sessions.md) for compaction boundaries,
cross-provider replay, and transcripts.

## Sub-agents

Delegate work into a child session so exploration does not consume the
parent's context. Only the report returns; the full child transcript stays
linked and inspectable.

```ruby
researcher = Mistri::SubAgent.new(
  name: "researcher",
  description: "Reads pages and answers factual questions.",
  provider: Mistri.provider("claude-haiku-4-5"),
  tools: [fetch_page],
)

agent = Mistri.agent("claude-opus-5", tools: [researcher.tool])
```

Mistri also provides an open spawn tool, background dispatch through your own
queue, worker reports, steering, stopping, and a management console. See
[Sub-agents](docs/sub-agents.md).

## Model Context Protocol

Bridge tools over Streamable HTTP or stdio, then apply the same local
approval and validation boundary:

```ruby
client = Mistri::MCP::Client.new(
  url: "https://mcp.linear.app/mcp",
  token: -> { connection.bearer_token },
)

tools = Mistri::MCP.tools(client, prefix: "linear", gates: { "create_issue" => true })
```

Remote URLs default to public HTTPS with validated, pinned DNS answers, and
an unconfirmed tool call is never replayed automatically. See
[MCP](docs/mcp.md).

## Skills, definitions, and workspaces

- **Skills** expose one-line descriptions until the model asks for the full
  `SKILL.md`, keeping the system prompt small.
- **Definitions** load an agent's model, tools, and prompt from Markdown with
  YAML frontmatter.
- **Workspaces** give the built-in read, write, edit, find, and list tools a
  directory, a memory value, an Active Record table, or a single host-owned
  value; the edit engine refuses ambiguous matches.

See [Context and workspaces](docs/context-and-workspaces.md) and the runnable
[`page_editor.rb`](examples/page_editor.rb) example.

## Reliability contract

Mistri makes failures explicit, but it does not pretend distributed side
effects are exactly once: tools with external side effects must be idempotent
or reconcilable, and budgets are soft ceilings checked between turns. The
complete operational contract lives in [Reliability](docs/reliability.md).

## Documentation

All primary documentation is versioned with the code and renders directly on
GitHub:

| Guide | What it covers |
| --- | --- |
| [Documentation index](docs/README.md) | The complete task-oriented map |
| [Tool contracts](docs/tool-contracts.md) | Schemas, validation, approval, hooks, results, and handoff |
| [Sessions and control](docs/sessions.md) | Stores, replay, approvals, steering, compaction, and transcripts |
| [Logging](docs/logging.md) | The run log, its options, and its operational guarantees |
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

Live tests read provider keys from the gitignored `.env.development.local`:

```console
$ MISTRI_LIVE=1 bundle exec rake test
$ bundle exec rake integration
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the project contract.

## Compatibility and support

Mistri supports Ruby 3.2 and newer. It is pre-1.0: minor releases may include
intentional contract changes with an explicit migration path; read
[UPGRADING.md](UPGRADING.md) before upgrading. Use
[GitHub issues](https://github.com/mcheemaa/mistri/issues) for reproducible
bugs and focused proposals, and report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md).

## Credits

Mistri's architecture is informed by [pi](https://github.com/badlogic/pi-mono)
by Mario Zechner. See [NOTICE](NOTICE).

## License

MIT. See [LICENSE](LICENSE).
