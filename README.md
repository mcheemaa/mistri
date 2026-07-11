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

A nested object without a block is deliberately freeform. This is useful for
provider-neutral configuration payloads whose keys Mistri should not prescribe:

```ruby
chart = Mistri::Tool.define("render_chart", "Renders a chart.", schema: lambda {
  object :config, "Chart-library configuration", required: true
}) do |args|
  Charts.render(args.fetch("config"))
end
```

This gives providers an open JSON object schema, where `{}` remains valid. Tool
arguments remain untrusted input. Mistri owns each completed JSON value and the
tool's provider-facing schema as immutable UTF-8, requires each completed
argument value to be an object, and validates its portable schema subset before
hooks, approval predicates, or handlers can see it. An invalid call receives an
error result the model can correct; valid calls from the same turn still run.
The core boundary never coerces model input; an explicit per-tool normalizer,
described below, is the deliberate compatibility exception. Arguments are
bounded at 8 MiB, 64 levels, 10,000 JSON nodes, and 64 KiB per numeric token;
the numeric ceiling applies to both encoded JSON and programmatic
custom-provider values. The byte ceiling includes the complete serialized JSON
shape, not only string payloads. Encoded Anthropic/OpenAI arguments take a
linear lexical width/depth pass before `JSON.parse`, so a wide or pathological
numeric document stops before allocating its full tree. Each completed outer
SSE record receives its own 20,001-token lexical preflight plus depth and 64 KiB
numeric-token ceilings. This bounds Gemini arguments before their enclosing
record is decoded; it is not a claim that an SSE envelope has already been
reduced to 10,000 canonical argument nodes. For fragmented Anthropic and OpenAI
calls, the byte ceiling applies across every delta; raw delta events still
arrive, while partial snapshots retain a bounded, deeply frozen preview that
refreshes on a capped schedule.

Completed calls also need non-empty UTF-8 string names, IDs, and opaque pairing
metadata, with IDs unique for the lifetime of the session. If a custom provider
violates that envelope, Mistri rejects the whole attempt before persistence or
policy and lets the configured provider retry request a clean turn; no sibling
tool runs from the malformed attempt.

`ToolCall#arguments_error?` is the public distinction between usable arguments
and a durable malformed call. Its non-nil string is an opaque diagnostic, not a
stable enum for application branching; use the predicate and the typed tool
result instead.

Every tool input schema must be a JSON Schema object with `type: "object"`.
A tool defined without a schema is a closed no-argument tool; undeclared model
fields are rejected before policy. Once a schema is supplied, object schemas
keep JSON Schema's default-open semantics unless a raw schema explicitly sets
`additionalProperties: false`. This includes DSL schemas with named properties,
so handlers should extract declared fields rather than mass-assign the argument
hash. Use a raw closed schema when extra keys must be rejected.
Mistri uses JSON Schema 2020-12; an omitted `$schema` means that dialect, an
explicit older dialect is rejected, and tuple arrays use `prefixItems` rather
than the pre-2020-12 array form of `items`. The built-in validator enforces JSON
types and type unions, `enum`, `required`, declared `properties`, `prefixItems`,
one-schema array `items`, nested boolean schemas, and boolean or schema-valued
`additionalProperties`. Other keywords remain provider-facing generation
guidance unless the tool supplies a complete validator. This includes
constraints such as `pattern`, `format`, and numeric or length bounds. An empty
object block currently emits the same open schema.

This freeform DSL shape cannot be represented by strict constrained output
without changing its meaning, so `Schema.strict` raises instead of silently
narrowing it to an object that only accepts `{}`. Use declared properties, or an
explicitly closed raw schema, for constrained task output.

Use `argument_validator:` for supplemental host or domain rules. It receives
the same deeply frozen arguments and canonical schema that policy and execution
use, and returns an array of model-readable violations. It cannot replace the
arguments or weaken a core failure:

```ruby
invoice = Mistri::Tool.define(
  "pay_invoice", "Pays an approved invoice.",
  input_schema: invoice_schema,
  argument_validator: lambda { |args, _schema|
    args["invoice_id"].start_with?("inv_") ? [] : ["$.invoice_id must identify an invoice"]
  }
) do |args|
  Invoices.pay!(args.fetch("invoice_id"))
end
```

Use `complete_argument_validator:` when a host validator implements the full
schema. It has the same `(args, schema)` contract, still runs only after core
passes, and is deliberately distinct from a supplemental validator. Any
non-empty `patternProperties` requires this explicit authority because core
cannot enforce a pattern's value schema even when unmatched keys remain open.
The two validator options are mutually exclusive.

Validator errors are bounded before they reach a model; they should still
describe expectations rather than include received field values or secrets.

`argument_normalizer:` is the separate, explicit compatibility seam for a tool
that intentionally accepts legacy aliases. It runs once before validation and
must return a JSON object; the normalized value is what policy sees, what a
human approves, and what the handler receives. It should be pure,
deterministic, and idempotent. A direct `Tool#call` is a trusted host invocation:
it applies that tool's normalizer for compatibility but does not run the Agent's
model-input validation boundary.

A tool result carries model content, host-only UI, and a failure fact. The
`ui` payload rides the `:tool_result` event and persists with the session, but
never reaches a provider. Return `error: true` for an expected tool failure
that the model should handle rather than treating as a successful answer:

```ruby
Mistri::Tool.define("edit_page", "Applies a page edit.", schema: -> {
  object :changes, "Page changes", required: true
}) do |args|
  page = apply(args.fetch("changes"))
  Mistri::ToolResult.new(content: "Saved.", ui: { "html" => page })
end

Mistri::Tool.define("lookup", "Looks up an account.", schema: -> {
  string :id, "Account ID", required: true
}) do |args|
  account = Accounts.find_by(id: args["id"])
  account || Mistri::ToolResult.new(content: "Account not found.", error: true)
end
```

Mistri also sets the flag for unknown tools, blocked calls, handler exceptions,
timeouts, calls interrupted before invocation, crash-healed calls whose outcome
is unknown, and failed `after_tool` hooks. `event.tool_error` and
`event.message.tool_error?` expose it without inspecting result text. A new
successful result records false; a reloaded legacy result without the field
keeps `tool_error == nil`, because Mistri cannot infer its historical outcome.
Human denial is an expected approval outcome and records false. Anthropic and
Gemini receive their native failure representation; OpenAI receives the same
explanatory output because its function-result shape has no error member.
Legacy unknown results replay with the historical unmarked provider shape;
Mistri never guesses their status from prose.

The flag means the call did not produce a confirmed successful result. It does
not mean retrying is safe: a handler can commit an external write before it
raises or times out. Mistri never mechanically replays the same call because
this flag is true, but the model may choose to issue another call. Hosts still
own idempotency, approval, and reconciliation for side effects.

Handlers and hooks can take the run's context as a second argument, and
`context.app` carries whatever object you pass as `Mistri.agent(context:)`
(the acting user, a tenant, a request), so tools stay authorization-aware
without closure gymnastics:

```ruby
agent = Mistri.agent("claude-opus-4-8", tools: tools,
                     context: { traveler: current_traveler })

Mistri::Tool.define("book_hotel", "Books the chosen hotel.", schema: -> {
  string :hotel_id, "Hotel ID", required: true
}) do |args, context|
  Bookings.create!(args.fetch("hotel_id"), traveler: context.app[:traveler])
end
```

A tool can also be the last word of its turn. `ends_turn: true` makes the
loop end the run once the tool executes, instead of prompting the model
again: an `ask_user` tool hands the floor to a human structurally, no
"remember to stop after asking" prompt required. `result.handed_off?` says the
model's floor was handed away; the persisted tool result says separately
whether execution confirmed success. The answer arrives as the next run's
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
                                 schema: lambda {
                                   number :total_usd, "Quoted total", required: true
                                 },
                                 needs_approval: ->(args) { args["total_usd"] > 500 }) do |args|
  Bookings.create!(total_usd: args.fetch("total_usd"))
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

The preceding assistant message remains the durable provider source. When a
normalizer changes arguments, the approval stores the exact prepared call the
human reviewed plus an explicit source marker. `resume` verifies pairing
metadata and revalidates those approved arguments without rerunning a
normalizer. Tool-call IDs are session-wide correlation keys; duplicate or
malformed legacy histories fail before a handler or provider runs. Persisted
results must follow one matching call with the same name and settle in call
order within each direct or approval phase; a compaction boundary cannot hide
an open approval or split a completed call from its result.

Only one Agent may actively call `run` or `resume` for a session at a time.
Concurrent appenders such as approval decisions, steers, and worker reports are
supported. The current execution contract is still at-least-once across the
gap between handler invocation and durable result persistence: a crash, store
failure, or subscriber exception in that gap can leave an approved call open,
and a later resume can execute it again. Simultaneous runners widen the same
risk. Until durable atomic claims land, hosts must serialize active runners and
make side effects idempotent or reconcilable.

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

Sessions can move between built-in providers. Opaque reasoning and pairing
metadata only replays to its provider of origin. In particular, a completed
foreign tool exchange becomes ordinary text for Gemini, preserving its result
without manufacturing a signed Gemini function call.

In Rails, generate a model (name it whatever you like) and use the
ActiveRecord store:

```console
$ bin/rails generate mistri:install AgentEntry
```

```ruby
require "mistri/stores/active_record"
store = Mistri::Stores::ActiveRecord.new(AgentEntry)
```

The `Stores::ActiveRecord` store needs LONGTEXT for `payload` on MySQL and Trilogy
because one legal parallel tool turn can exceed MEDIUMTEXT even when each call
stays inside its own limit. The generator uses `size: :long` for new
MySQL-family tables. An existing installation needs its own migration; changing
the generator cannot widen a table that already exists:

```ruby
change_column :agent_entries, :payload, :text, size: :long, null: false
```

## Compaction

Long sessions survive their context window: when the conversation grows into
the model's safe headroom, the provider writes a visible structured summary
and replay continues from it. The full history stays exact in your store for
transcript views. On by default whenever the model's window is known;
`compaction: false` disables it.

For a catalogued model, Mistri automatically reserves its full output capacity
plus 4,096 tokens for framing and estimation when input and output share one
context window. Gemini publishes independent input and output limits, so its
automatic input reserve remains 16,384 tokens. An uncatalogued model with a
host-supplied `window:` also uses that 16,384-token fallback; set `reserve:`
explicitly when the deployment needs different output headroom. An explicit
reserve is also a useful quality policy when you prefer an earlier checkpoint
to counter context rot.

```ruby
agent.context_usage   # => { tokens: 141_000, window: 1_000_000, fraction: 0.141 }
agent.compact         # the manual button

Mistri::Compaction.new(reserve: 64_000) # explicit quality policy
```

`:compacting` and `:compaction` events carry the summary, so users see
exactly what the model still remembers. A single run can compact between tool
turns without splitting a tool call from its results. Very large tool results
are shortened only in the request sent to the summarizer. That shortening
never mutates the durable result or an ordinary request that still replays it.
Once compaction commits, replay intentionally becomes the visible summary plus
its kept tail.

## Task mode

A run that must end in JSON matching a schema. Tools run as usual; providers
constrain the final answer natively where they can, and the answer is
validated client-side everywhere. A violation goes back to the model once,
then raises. Task output uses the same portable subset and 8 MiB, 64-level,
10,000-node, and 64 KiB numeric-token limits as tool input. A schema containing
an assertion outside that subset fails at configuration time instead of
claiming a guarantee Mistri cannot enforce. The prompt and final local check
share one deeply frozen strict schema snapshot. Each provider derives a native
constraint only when its structured-output subset can represent that contract,
the model is catalogued for that provider, and documented complexity ceilings
are satisfied. Otherwise Mistri omits the native constraint and relies on the
same prompt, validation, and correction loop. You get a guaranteed shape or a
loud error, never silence.

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

Everything cross-process (stopping a worker from another process, the
`:interrupted` liveness read, and the lease fence below) rides a lock
adapter; configure one at boot. Without it, workers still run, but stops
need the parent's own signal, a crashed child reads `:running`, and
dispatched retries are unfenced:

```ruby
Mistri.locks = Mistri::Locks::RailsCache.new   # Locks::Memory for a single process
```

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

Common MCP map input schemas work with Mistri's portable validator through
schema-valued `additionalProperties`. Because a remote schema can guard approval
policy, any standard assertion outside that subset requires the host's explicit,
zero-coercion complete validator:

```ruby
tools = Mistri::MCP.tools(
  client,
  complete_argument_validator: ->(args, schema) { validator.errors(args, schema) }
)
```

Omitted MCP `inputSchema` means a no-argument object. Explicit `null` and
non-object roots are configuration errors. Same-document `$ref` and
`$dynamicRef` values are accepted only with a complete validator; external
references are rejected so validation never performs hidden network or file
resolution.

Remote URLs are untrusted input. Mistri accepts public HTTPS destinations by
default, rejects the whole DNS result when any answer is non-public, and pins an
approved address while keeping the hostname for Host, SNI, and certificate
verification. Each connection cycle resolves and validates every DNS answer;
Net::HTTP's internal keep-alive reconnects start a new cycle. Approved
candidates from one result are tried only before request bytes are sent. MCP
and server-side OAuth requests do not follow redirects or inherit ambient HTTP
proxy settings.

Private MCP and authorization servers remain available through one narrow host
policy, passed to the client and every OAuth operation:

```ruby
INTERNAL_RANGE = IPAddr.new("10.20.0.0/16")
ALLOW_INTERNAL_MCP = lambda do |uri, address|
  %w[mcp.internal.example auth.internal.example].include?(uri.hostname) &&
    INTERNAL_RANGE.include?(address)
end

# Override this hook in a generated Rails connection model.
class McpConnection
  def self.mcp_allow_non_public = ALLOW_INTERNAL_MCP
end

client = Mistri::MCP::Client.new(url: "https://mcp.internal.example/mcp",
                                 allow_non_public: ALLOW_INTERNAL_MCP)
```

The callback is consulted only for non-public addresses; it cannot permit an
invalid URL or plaintext HTTP to a non-loopback destination. Local development
can explicitly use `->(_uri, address) { address.loopback? }`.

The bridge lists the server's tools once, at build time; `client.tools(refresh: true)`
re-lists when a host wants a changed toolset. Discovery rejects repeated cursors
and defaults to 100 pages or 10,000 tools; `max_tool_pages:` and `max_tools:`
let a host set explicit limits. `prefix:` namespaces local names
(`linear__create_issue`) because duplicate tool names raise at `Agent.new`:
collisions fail loud instead of one server's tool silently shadowing another's.

Inbound JSON bodies, individual SSE lines, and stdio JSON records default to an
8 MiB `max_record_bytes:` ceiling. It limits one atomic record, not the total
length of a stream. Each completed SSE JSON record also gets one bounded linear
lexical scan with a 20,001-token ceiling, plus depth and 64 KiB numeric-token
ceilings, before parsing. That scan can raise `ResponseTooComplexError`; byte
overflow raises `ResponseTooLargeError`. Both errors carry `kind` and `limit` as
machine-readable data.

Either boundary closes and resets the MCP wire, including its session, protocol
version, and server information, so the next operation performs a fresh
handshake. If an unconfirmed `tools/call` crosses either boundary, Mistri raises
`AmbiguousDeliveryError`: the operation may have completed and must not be
retried automatically. A matching result received before an invalid trailing
SSE record remains authoritative, but the wire is still reset. For a trusted
server, configure a larger explicit byte limit; the structural ceilings remain
fixed.

Large tool output is better stored by the server or host and returned as an MCP
`resource_link`; Mistri renders its URI for the model and never fetches the
target itself.

Local stdio servers spawn as child processes, credentials in their
environment. That is also the whole "give the agent a browser" story:

```ruby
browser = Mistri::MCP::Client.new(
  command: ["npx", "-y", "@playwright/mcp@latest", "--browser", "chrome", "--headless"],
  max_record_bytes: 16 * 1024 * 1024, # explicit trust for larger screenshots
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
application: `client_name:` is yours to set. The generated row persists the
authorization-server identity selected during registration; token endpoints
are rediscovered from that exact issuer before code exchange and refresh.

```ruby
connection, authorize_url = McpConnection.connect(
  name: "Linear", url: params[:url],
  client_name: "YourApp", redirect_uri: mcp_callback_url,
)
# redirect the user to authorize_url; then, in the callback:
connection = McpConnection.complete(state: params[:state], code: params[:code])

agent = Mistri.agent("claude-opus-4-8", tools: connection.tools(prefix: "linear"))
```

When calling the low-level OAuth services directly, persist `flow["issuer"]`
and `flow["resource"]`, verify callback state against `flow["state"]`, and pass
the same `allow_non_public:` callback to `start`, `complete`, and `refresh` for
an internal server. A pre-registered `client_id` belongs to a specific
authorization server, so `start` requires the exact trusted `issuer:` supplied
when that client was registered. If protected-resource metadata advertises
more than one issuer, the host must select one explicitly. `start` still
returns `token_endpoint` for compatibility, but `complete` and `refresh` do
not trust it; they rediscover the current endpoint from `issuer`.

Generated models copied by an older Mistri release are not rewritten when the
gem updates. Before using this version, add an `issuer` string column, pass it
to `complete` and `refresh`, and thread one class-owned egress policy through
all three OAuth operations and `Client` if non-public destinations are used.
Restart pending OAuth flows. Existing connected rows may be backfilled only
when the application independently recorded the exact issuer used during
registration; otherwise reconnect them. Never infer an issuer from a token
endpoint. The current generator shows the complete wiring.

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

# Ceilings are opt-in and off by default. Dollar cost uses each request's
# published paid-list rate, including long-context tiers and dated changes.
budget = Mistri::Budget.new(turns: 20, cost_usd: 2.00)

# Anthropic and OpenAI need an explicit standard tier for a cost budget.
agent = Mistri.agent("gpt-5.6-terra", budget: budget,
                     provider_options: { service_tier: "default" })

# Transient failures (429, 5xx, timeouts) retry with backoff, invisibly to
# the model. On by default; retries: false disables.
policy = Mistri::RetryPolicy.new(attempts: 3)
```

Cost is explicit: `result.usage.cost.known?` is false when Mistri cannot
price every turn. Constructing an agent with `cost_usd` therefore requires a
catalogued model, a list-priced origin, and deterministic standard-tier policy
instead of treating unknown cost as free. Anthropic uses `standard_only`;
OpenAI uses `default`; Gemini's omitted tier is standard by contract. All
ceilings are checked between model-visible turns, so the final turn, including
its provider retry attempts, can exceed one. If an attempted request has no
trustworthy usage, the run raises `BudgetError` and does not retry it. The
error exposes `usage` and `provider_message`, and the session records an
`unpriced_attempt` entry for reconciliation. Reported dollars are standard paid
direct-API list-price estimates; contracted or regional uplifts and separately
billed provider tools are outside this total.
Gemini free-tier usage is conservatively valued at the paid rate.

Built-in providers disable catalog pricing for a custom `origin:`. Pass
`catalog_pricing: true` only when that route bills the same published rates.
Pricing never changes service-tier policy. Anthropic and OpenAI usage is known
only when the response reports their standard tier; Priority, Flex, or a
missing tier stays unknown. A host that needs deterministic list-price
budgeting can select it explicitly with `provider_options: { service_tier:
"standard_only" }` for Anthropic or `"default"` for OpenAI. Gemini observes
`usageMetadata.serviceTier`; Flex and Priority are unpriced by this catalog.
A custom provider can support cost ceilings by returning true from
`prices_usage?` and attaching a known cost to every response, commonly with
`Mistri::Usage#with_cost`; missing or partial pricing then fails closed at
runtime.

Retries are invisible to the model but not to your UI: each backoff emits a
`:retry` event carrying `attempt`, `max_attempts`, and `delay`, so a sink can
show a live "reconnecting" state instead of a silent spinner. Terminal events
are loop-owned: `:done` and `:error` reach the subscriber only for the
accepted attempt, so a recovered retry never flashes an error it then walks
back.

Every provider attempt begins with one `:start` event carrying an immutable
empty assistant snapshot. Each opened text, thinking, or tool-call block then
has a matched start/delta/end sequence, including before a terminal failure.

Built-in assemblers fail malformed known stream lifecycles instead of accepting
content that could become executable. Terminal records fence later known
content. Anthropic requires sequential/open block indexes and a delta kind that
matches the open block. OpenAI requires one open item, checks its kind and any
present item/output correlation fields on known deltas, and requires terminal
event and response status to agree. Unknown future event and block types remain
ignorable for forward compatibility. Interrupted tool calls remain marked
incomplete and are removed before Agent persistence or execution.

Tool execution emits `:tool_started` when each resolved call commits to
execution, then `:tool_result` with an explicit `tool_error` boolean. Calls
still queued behind `max_concurrency`, blocked by policy, waiting for approval,
denied, unknown, or interrupted before invocation never claim to have started.
Starts arrive from tool worker threads as execution begins; sinks must tolerate
serialized callbacks from those threads. Results settled in the same batch
retain deterministic model-call order and emit after the parallel batch joins,
as before. A subscriber exception from `:tool_started` or handler-emitted
progress propagates to the run and never becomes a tool result.
Event types are an extensible union; subscribers should handle the types they
use and ignore the rest.

```ruby
agent.run("Plan the itinerary.") do |event|
  case event.type
  when :text_delta then stream(event.delta)
  when :retry then banner("Retrying (#{event.attempt}/#{event.max_attempts}) in #{event.delay}s")
  when :tool_started then tool_running(event.tool_call)
  when :tool_result then tool_finished(event.tool_call, failed: event.tool_error)
  when :done, :error then clear_banner
  end
end
```

## Images and provider options

```ruby
photo = Mistri::Content::Image.from_bytes(File.binread("chart.png"), mime_type: "image/png")
photo = Mistri::Content::Image.from_data_uri(params[:image])   # canvases and uploads
agent.run("What trend does this chart show?", images: [photo])

Mistri.agent("gpt-5.6", provider_options: { reasoning: { effort: "high" } })
Mistri.agent("claude-opus-4-8", provider_options: { cache: false })
Mistri.agent("gemini-3.1-pro-preview",
             provider_options: { max_record_bytes: 16 * 1024 * 1024 })
```

## Testing

`rake test` is hermetic and fast. The Fake provider streams like the real
ones for ordinary small fixtures, tool-call arguments included: its eager
partials make UI tests simple, while real Anthropic/OpenAI assemblers expose a
bounded cached preview under adversarial fragmentation. A UI that renders tool
input as it arrives still tests headless. `rake integration` runs every feature
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

Next up: atomic cross-process claims for active session runners,
provider-native MCP passthrough, optional full JSON Schema adapters, and
resource-backed handling for very large tool results.

## Credits

Mistri's architecture is informed by [pi](https://github.com/badlogic/pi-mono)
by Mario Zechner. See NOTICE.

## License

MIT. See LICENSE.
