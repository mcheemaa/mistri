<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="مستری" width="360">
  </picture>
</p>

<p align="center"><strong>mistri</strong>, the agent harness for Ruby applications.</p>

<p align="center"><a href="https://mistri.sh">mistri.sh</a> · <a href="https://mistri.sh/docs/getting-started/">docs</a></p>

<p align="center">
  <a href="https://rubygems.org/gems/mistri"><img alt="Gem Version" src="https://img.shields.io/gem/v/mistri"></a>
  <a href="https://github.com/mcheemaa/mistri/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mcheemaa/mistri/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://codecov.io/gh/mcheemaa/mistri"><img alt="Coverage" src="https://img.shields.io/codecov/c/github/mcheemaa/mistri"></a>
  <a href="mistri.gemspec"><img alt="Ruby >= 3.2" src="https://img.shields.io/badge/ruby-%3E%3D%203.2-CC342D"></a>
  <a href="Gemfile"><img alt="Runtime dependencies: zero" src="https://img.shields.io/badge/runtime_deps-0-brightgreen"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

A mistri (Urdu: مستری) is the fixer: the skilled tradesperson who actually
gets it done. This one lives inside your app, not in a terminal. It runs the
model loop, executes tools, streams every event, persists sessions to your
own database, and pauses for a human when a tool needs approval, all with
zero runtime gem dependencies.

```ruby
require "mistri"

weather = Mistri::Tool.define(
  "get_weather", "Current weather for a city.",
  schema: -> { string :city, "City name", required: true },
) do |args|
  Weather.for(args["city"])
end

agent = Mistri.agent("claude-opus-4-8", tools: [weather]) # reads ANTHROPIC_API_KEY

agent.run("What should I wear in Lahore today?") do |event|
  print event.delta if event.type == :text_delta
end
```

## Why Mistri

- **Built for applications.** Sessions are durable, append-only records in
  your own store. Runs stop, resume, steer, and compact from any process.
- **Fire-and-forget human approval.** A gated tool suspends the run and
  returns immediately. The approval can arrive two days later from a bare
  web request; nothing sleeps waiting.
- **Three providers, frontier-deep.** Anthropic, OpenAI, and Gemini, each
  streamed natively with thinking, prompt caching, parallel tool calls, and
  constrained JSON output. One message model across all three.
- **Zero runtime dependencies.** Plain Ruby all the way down.
- **Verified against real APIs.** A live integration harness runs every
  feature end to end on every provider (`rake integration`).

## Install

```ruby
gem "mistri"
```

## Sixty-second start

```ruby
agent = Mistri.agent("claude-opus-4-8")
result = agent.run("Name three Ruby web frameworks.")
puts result.text
```

`Mistri.agent` infers the provider from the model id (`claude-*`, `gpt-*`,
`gemini-*`) and reads the matching key (`ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GEMINI_API_KEY`); pass `api_key:` to set it explicitly.
Every run returns a `Result`: `completed?`, `awaiting_approval?`,
`aborted?`, `errored?`, with `text` and (for tasks) `output`.

## Tools

A tool is a name, a description, an argument schema, and a block. The block
returns a String, a Hash (sent as JSON), or content such as an image. The
agent calls tools, feeds results back, and loops until the model answers;
independent calls in a turn run in parallel.

```ruby
weather = Mistri::Tool.define("get_weather", "Current weather for a city.", schema: lambda {
  string :city, "City name", required: true
  string :units, "Temperature units", enum: %w[celsius fahrenheit]
}) do |args|
  Weather.for(args["city"], units: args["units"] || "celsius")
end
```

A tool can speak on two channels: `content` for the model, `ui` for your
interface. The `ui` payload rides the `:tool_result` event and persists with
the session, but never reaches a provider:

```ruby
Mistri::Tool.define("edit_page", "Applies a page edit.") do |args|
  page = apply(args)
  Mistri::ToolResult.new(content: "Saved.", ui: { "html" => page })
end
```

Handlers and hooks can take the run's context as a second argument, and
`context.app` carries whatever object you pass as `Mistri.agent(context:)`
(the acting user, a tenant, a request), so tools stay authorization-aware
without closure gymnastics:

```ruby
agent = Mistri.agent("claude-opus-4-8", tools: tools,
                     context: { traveler: current_traveler })

Mistri::Tool.define("book_hotel", "Books the chosen hotel.") do |args, context|
  Bookings.create!(args, traveler: context.app[:traveler])
end
```

A tool can also be the last word of its turn. `ends_turn: true` makes the
loop end the run once the tool executes, instead of prompting the model
again: an `ask_user` tool hands the floor to a human structurally, no
"remember to stop after asking" prompt required. The result says it
happened (`result.handed_off?`), and the answer arrives as the next run's
input:

```ruby
ask_user = Mistri::Tool.define("ask_user", "Ask the human and wait.",
                               ends_turn: true,
                               schema: -> { string :question, "The question", required: true }) do |args|
  "Question presented to the user."
end
```

## Human approval

Mark a tool `needs_approval: true` (or a predicate on its arguments) and the
run suspends instead of executing it, instantly, with no thread waiting.
The decision is a one-line session write from any process, any time later;
`resume` settles it and carries on.

```ruby
book_hotel = Mistri::Tool.define("book_hotel", "Books the chosen hotel.",
                                 needs_approval: ->(args) { args["total_usd"].to_i > 500 }) do |args|
  Bookings.create!(args)
end

result = agent.run("Book the corner suite for the Lisbon trip")
result.awaiting_approval?   # => true; nothing executed

# Days later, in a controller:
Mistri::Session.new(store:, id: session_id).approve(call_id)   # or .deny(call_id, note: "...")

# Then, in a worker:
Mistri.agent("claude-opus-4-8", tools: tools, session: reloaded).resume
```

The harness renders nothing: it emits an `:approval_needed` event and your
app draws the UI.

## Steering

Queue a message into a running exchange from any process. It folds into the
conversation at the next turn boundary; one that arrives as the model
finishes cleanly extends the run so it gets answered.

```ruby
Mistri::Session.new(store:, id: session_id).steer("Make the headline blue instead.")
```

Background workers' reports arrive through the same inbox (see Sub-agents).
A host that wakes an idle session when a steer lands should watch
`session.pending_inbox`, which holds both, in arrival order.

## Sessions

A session is the durable record of a run: an append-only entry log over a
pluggable store (memory, JSONL files, or your database).

```ruby
store = Mistri::Stores::JSONL.new("tmp/sessions")
session = Mistri::Session.new(store:)

agent = Mistri.agent("claude-opus-4-8", session:)
agent.run("Start a haiku about the sea.")

# Later, even in another process: reload by id and continue.
resumed = Mistri.agent("claude-opus-4-8", session: Mistri::Session.new(store:, id: session.id))
resumed.run("Now finish it.")
```

In Rails, generate a model (name it whatever you like) and use the
ActiveRecord store:

```console
$ bin/rails generate mistri:install AgentEntry
```

```ruby
require "mistri/stores/active_record"
store = Mistri::Stores::ActiveRecord.new(AgentEntry)
```

## Compaction

Long sessions survive their context window: when the conversation grows into
the reserve headroom, the provider writes a visible structured summary and
replay continues from it. The full history stays in your store for
transcript views. On by default whenever the model's window is known;
`compaction: false` disables it.

```ruby
agent.context_usage   # => { tokens: 141_000, window: 200_000, fraction: 0.705 }
agent.compact         # the manual button
```

`:compacting` and `:compaction` events carry the summary, so users see
exactly what the model still remembers.

## Task mode

A run that must end in JSON matching a schema. Tools run as usual; providers
constrain the final answer natively where they can, and the answer is
validated client-side everywhere. A violation goes back to the model once,
then raises. You get a guaranteed shape or a loud error, never silence.

```ruby
schema = {
  type: "object",
  properties: { "tiers" => { type: "array", items: { type: "string" } } },
  required: ["tiers"],
}

result = agent.task("Extract the pricing tiers from this page.", schema: schema)
result.output # => { "tiers" => [...] }, parsed and validated
```

A run that suspends for approval, or that an `ends_turn` tool ended,
returns as-is: validation applies to answers, not handoffs. Route on
`result.handed_off?` and ask again once the human's answer arrives.

## Skills

Expert playbooks with progressive disclosure: each skill costs one line in
the system prompt until the model decides it is relevant and pulls the full
body through an auto-provided `read_skill` tool.

```ruby
agent = Mistri.agent("claude-opus-4-8", skills: "app/skills")   # or an array of Mistri::Skill
```

A skill is a `SKILL.md` (or flat `.md`) with `name:`/`description:`
frontmatter, or built from database rows with
`Mistri::Skill.new(name:, description:, body:)`.

## Definitions

An agent as a markdown file: YAML frontmatter for config, the body as the
prompt, `{placeholders}` filled at build time (unfilled ones raise). Tool
names and any extra keys stay your vocabulary; the gem only reads the
file.

```ruby
definition = Mistri::Definition.load("app/agents/trip_planner.md")
agent = Mistri.agent(definition.model,
                     system: definition.render(first_name: traveler.first_name),
                     tools: registry.build(definition.tools, traveler))
```

## Sub-agents

Delegate to a child agent with a clean context: exploration fills the
child's window, and only the final answer returns. Children run on their own
sessions in your store, linked in the parent transcript; their events stream
into the parent tagged with an `origin`. Each run of a specialist can carry
its own name, so two parallel researchers read as Corgi and Beagle in your
UI instead of "researcher" twice.

```ruby
researcher = Mistri::SubAgent.new(
  name: "researcher", description: "Reads pages and answers factual questions.",
  provider: Mistri.provider("claude-haiku-4-5-20251001"),   # cheaper model for grunt work
  system: "Research. Report findings only.", tools: [fetch_page],
)
agent = Mistri.agent("claude-opus-4-8", tools: [researcher.tool])
```

Or hand the model an open spawn tool and let it compose its own workers:
a name, instructions, a tool subset, and a host-allowlisted model per
child. Several spawns in one turn fan out in parallel. `pack` is the whole
kit: the spawn tool plus a management console (`list_agents`, `read_agent`,
`steer_agent`, `stop_agent`), with curated types and an optional
dispatcher:

```ruby
spawn = Mistri::SubAgent.spawner(provider: provider, tools: [fetch_page, search])

tools = Mistri::SubAgent.pack(
  provider: provider, tools: [fetch_page, search],
  types: { "researcher" => Mistri::Definition.load("agents/researcher.md") },
  models: ["claude-haiku-4-5-20251001"],
  dispatcher: Mistri::Dispatchers::Thread.new,      # or one lambda onto your queue
)
```

A typed worker takes its prompt, tools, and model from the host's
definition; `general-purpose` stays open for the model to compose.
`max_children` (default 4) caps live workers, and every policy violation
answers the model in band.

With a dispatcher, `spawn_agent` takes `mode: "background"`: the model gets
a truthful receipt at once and keeps working while the child runs. The
console manages the roster with the same functions a host UI calls, so
agent and user control stay structurally equal: either can read a worker's
transcript, steer it mid-run, or stop it, from any process. When a worker
finishes, its report delivers itself: a typed entry queues in the parent's
inbox and folds at the next turn boundary as `[Corgi finished] <report>`
(failures carry the error), while a `:subagent_report` event settles the
worker's lane in whatever UI watched the spawn. In a queue host, the job
rebuilds tools from the serializable spec and calls
`SubAgent.run_dispatched`, which fences on the child's lease: a redelivered
job leaves the running owner alone, a retry of a finished child is a no-op,
and a retry of a crashed one runs it again.

Everything about a child derives from the store and reads the same from
any process, while it runs and forever after:

```ruby
session.children               # => [#<Mistri::Child Corgi running>, ...]
child.status                   # :queued, :running, :done, :stopped, :failed
child.report                   # the terminal entry's report, once finished
child.say("Check pricing too") # folds at the child's next turn boundary
child.stop                     # cooperative, cross-process, within a tick

session.transcript(include_children: true)
# the whole conversation, each child's log spliced at its link entry and
# origin-tagged like the live stream: a reloading UI rebuilds its lanes
```

## Editing documents

The document tools (`read_file`, `edit_file`, `write_file`, `find_in_file`,
`list_files`) work over a workspace: a directory, memory, ActiveRecord, or
a single value anywhere, like one database column holding a page:

```ruby
workspace = Mistri::Workspace::Single.new(
  read: -> { page.html },
  write: ->(html) { page.update!(html: html) },
  path: "hero.html",
)
agent = Mistri.agent("claude-opus-4-8", tools: Mistri::Tools.files(workspace))
```

The edit engine matches exactly, then whitespace-tolerantly; an ambiguous
match refuses (never silently edits the wrong place), and a near-miss error
names the closest region so the model's retry is one-shot.

## MCP

Bridge any Model Context Protocol server's tools into an agent. The client
speaks Streamable HTTP with zero new dependencies; auth is a token string
or a lambda that re-resolves once on 401, so refresh logic lives in one
place. Approval gates compose: a third-party write tool can require a
human.

```ruby
client = Mistri::MCP::Client.new(url: "https://mcp.linear.app/mcp",
                                 token: -> { connection.bearer_token })
tools = Mistri::MCP.tools(client, prefix: "linear",
                          gates: { "create_issue" => true })

agent = Mistri.agent("claude-opus-4-8", tools: tools)
```

The bridge lists the server's tools once, at build time; `client.tools(refresh: true)`
re-lists when a host wants a changed toolset. `prefix:` namespaces local
names (`linear__create_issue`) because duplicate tool names raise at
`Agent.new`: collisions fail loud instead of one server's tool silently
shadowing another's.

Local stdio servers spawn as child processes, credentials in their
environment. That is also the whole "give the agent a browser" story:

```ruby
browser = Mistri::MCP::Client.new(
  command: ["npx", "-y", "@playwright/mcp@latest", "--browser", "chrome", "--headless"],
)
agent = Mistri.agent("claude-opus-4-8",
                     tools: Mistri::MCP.tools(browser, allow: %w[browser_navigate browser_snapshot]))
```

For the full connect-your-tools story in Rails, generate a connection model
(name it whatever you like):

```console
$ bin/rails generate mistri:mcp McpConnection
```

Each row is one server connection carrying its own OAuth flow state and
encrypted tokens. The OAuth services underneath (`Mistri::MCP::OAuth.start`,
`.complete`, `.refresh`) are storage-agnostic, so the same flow works from a
controller, a GraphQL mutation, or a job. Registration happens as your
application: `client_name:` is yours to set.

```ruby
connection, authorize_url = McpConnection.connect(
  name: "Linear", url: params[:url],
  client_name: "YourApp", redirect_uri: mcp_callback_url,
)
# redirect the user to authorize_url; then, in the callback:
connection = McpConnection.complete(state: params[:state], code: params[:code])

agent = Mistri.agent("claude-opus-4-8", tools: connection.tools(prefix: "linear"))
```

## Streaming into Rails

Sinks bridge the event stream to a transport, and compose as blocks:

```ruby
cable = Mistri::Sinks::ActionCable.new("agent_#{session.id}")
sink = Mistri::Sinks::Coalesced.new(cable) # merges token bursts to UI speed

agent.run(input, &sink)
```

`Mistri::Sinks::SSE.new(response.stream)` does the same for
`ActionController::Live`. There is no Railtie and nothing to configure;
the generator and stores duck-type into any app.

## Stopping, budgets, reliability

```ruby
# Trip the signal from anywhere; the partial turn persists, resume is clean.
signal = Mistri::AbortSignal.new
agent.run("Draft a long essay.", signal: signal)

# Ceilings are opt-in and off by default.
budget = Mistri::Budget.new(turns: 20, cost_usd: 2.00)

# Transient failures (429, 5xx, timeouts) retry with backoff, invisibly to
# the model. On by default; retries: false disables.
policy = Mistri::RetryPolicy.new(attempts: 3)
```

Retries are invisible to the model but not to your UI: each backoff emits a
`:retry` event carrying `attempt`, `max_attempts`, and `delay`, so a sink can
show a live "reconnecting" state instead of a silent spinner. Terminal events
are loop-owned: `:done` and `:error` reach the subscriber only for the
accepted attempt, so a recovered retry never flashes an error it then walks
back.

```ruby
agent.run("Plan the itinerary.") do |event|
  case event.type
  when :text_delta then stream(event.delta)
  when :retry then banner("Retrying (#{event.attempt}/#{event.max_attempts}) in #{event.delay}s")
  when :done, :error then clear_banner
  end
end
```

## Images and provider options

```ruby
photo = Mistri::Content::Image.from_bytes(File.binread("chart.png"), mime_type: "image/png")
photo = Mistri::Content::Image.from_data_uri(params[:image])   # canvases and uploads
agent.run("What trend does this chart show?", images: [photo])

Mistri.agent("gpt-5.5", provider_options: { reasoning: { effort: "high" } })
Mistri.agent("claude-opus-4-8", provider_options: { cache: false })
```

## Testing

`rake test` is hermetic and fast. The Fake provider streams like the real
ones, tool-call arguments included: each delta's partial carries the
in-progress call with arguments parsed so far, so a UI that renders tool
input as it arrives tests headless. `rake integration` runs every feature
end to end against real provider APIs, once per model in the matrix: an
Anthropic, an OpenAI, and a Gemini model by default. Scenarios assert that
coined codenames (a ghost of a word like `Wraithowyn` exists in no training
data) flowed through tool results, summaries, and child agents: proof of
information flow, not model knowledge.

```console
$ bundle exec rake integration
$ MISTRI_INTEGRATION_MODELS=claude-opus-4-8 bundle exec rake integration
```

## Roadmap

Next up: strict tool schemas, provider-native MCP passthrough, and the
hardening that falls out of the first production applications.

## Credits

Mistri's architecture is informed by [pi](https://github.com/badlogic/pi-mono)
by Mario Zechner. See NOTICE.

## License

MIT. See LICENSE.
