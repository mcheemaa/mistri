# Reliability

Mistri makes the execution boundary explicit. It does not turn a model call,
network, process, database, and external side effect into one transaction.

The core rule is simple: the gem owns mechanism; the host owns policy. Mistri
validates and records what it can know. The application supplies authorization,
runner serialization, idempotency, reconciliation, queue guarantees, and UI.

## Result and error model

Every run returns `Mistri::Result` unless a separate host contract must raise:

```ruby
result.completed?
result.awaiting_approval?
result.aborted?
result.stopped_by_budget?
result.errored?
result.handed_off?
```

`result.text` reads the final assistant message. `result.output` is the parsed,
validated value from task mode. `result.usage` sums provider attempts and
compaction calls made during that invocation.

Failures the model can correct stay in band. Unknown tools, invalid arguments,
policy blocks, expected tool failures, handler exceptions, and timeouts become
typed tool results. Valid sibling calls may still execute.

Built-in provider failures, including exhausted retries and provider response
limits, finish as `result.errored?`. Configuration and Session contract failures,
final task validation, and unknown-cost reconciliation raise a `Mistri::Error`
subclass. Store and subscriber callbacks can propagate their own exceptions.

Direct MCP Client failures raise. A tool bridged through `Mistri::MCP.tools`
runs inside the tool executor, so its Client exception, including ambiguous
delivery, becomes an error-marked tool result. The transport has not replayed
the call; the model may still choose to issue a new one.

Rescue `Mistri::Error` for the gem's public error family. Do not rescue
`StandardError` around the entire run and silently convert programming or
subscriber bugs into model output.

## Side-effect outcomes can be ambiguous

Only one Agent may actively call `run` or `resume` for a Session at a time. The
store can accept independent approval, steer, and worker-report appends, but
active runners are a host scheduling concern.

Even with one runner, this gap remains:

1. Mistri records that a call is ready.
2. The handler commits an external write.
3. The process, subscriber, or store fails before the result append.

On replay, Mistri can prove that the call has no durable result. It cannot prove
whether step 2 happened. The Session synthesizes an interrupted error so the
provider transcript remains pairable and tells the caller to verify effects.

Build write tools around a domain idempotency key or reconciliation handle:

```ruby
Mistri::Tool.define(
  "send_gift", "Sends one gift order.",
  schema: lambda {
    string :order_id, "Host-issued idempotency key", required: true
    string :recipient_id, "Recipient ID", required: true
  },
) do |args|
  GiftOrders.create_once!(
    idempotency_key: args.fetch("order_id"),
    recipient_id: args.fetch("recipient_id"),
  )
end
```

The exact mechanism belongs to the application and its downstream system. For
some APIs it is an idempotency header; for a database it may be a unique key and
transaction; for an irreversible operation it may require a reconciliation
screen instead of automatic retry.

Approval reduces authorization risk but does not make execution exactly once.
Mistri guarantees neither exactly-once execution nor eventual at-least-once
delivery: a call may run once, more than once after host or model retry, or not
at all. Durable facts tell the host what is known; idempotency and reconciliation
decide what to do next.

## Provider retries

Transient provider failures retry with jittered exponential backoff by default:

```ruby
policy = Mistri::RetryPolicy.new(
  attempts: 3,    # retries; up to four total requests
  base: 1.0,
  max_delay: 30.0,
)

agent = Mistri.agent("claude-opus-4-8", retries: policy)
```

Set `retries: false` to disable the Agent retry loop.

Rate limits, overload, timeouts, selected server statuses, dropped or truncated
streams, and empty completions are retryable. Authentication errors, invalid
requests, content-policy refusals, unsafe configuration, and host bugs fail
fast. A provider `Retry-After` value is honored within `max_delay`.

Each retry sends unchanged durable history. Failed attempts are not appended as
conversation messages, but their usage and retry record remain available for
accounting.

The subscriber receives `:retry` with `attempt`, `max_attempts`, and `delay`.
Only the accepted provider attempt's `:done` or `:error` event is released, so a
recovered retry does not flash a terminal failure and then retract it.

MCP `tools/call` is intentionally different. Once sent, a missing response is
an ambiguous side effect and is not replayed by the Client. The Agent bridge
returns that exception as an error-marked tool result. See
[Ambiguous tool delivery](mcp.md#ambiguous-tool-delivery).

## Events and sinks

Every built-in provider attempt emits:

1. `:start` with an empty immutable assistant snapshot;
2. matched start and end events for each recognized text, thinking, or tool-call
   block, with zero or more delta events as content arrives.

A retried attempt's terminal event is suppressed and `:retry` is its visible
boundary. Only the accepted attempt releases exactly one `:done` or `:error`.
Block deltas from the failed attempt may already have reached the subscriber;
on `:retry` or the next `:start`, a UI must reset or replace that ephemeral
attempt instead of appending it to the next one. Only the accepted Message is
persisted.

A custom provider must emit the same lifecycle when host subscribers depend on
streaming; the Agent does not synthesize provider events around `stream`.

Those terminal events end one provider turn, not necessarily the Agent run. If
the turn calls tools, the Agent emits tool lifecycle events, appends results,
and starts another provider turn.

Loop-level events are:

- `:tool_started` when a resolved call commits to handler invocation;
- `:tool_result` after settlement, with a required `tool_error` boolean;
- `:approval_needed` when a prepared call parks;
- `:compacting` before summary work and `:compaction` with the committed
  summary in `content`;
- `:retry` before provider backoff;
- `:subagent_report` when a background child reaches a terminal state.

Event types form an extensible union. Handle the types the application uses and
ignore the rest:

```ruby
agent.run(input) do |event|
  case event.type
  when :text_delta
    stream_text(event.delta)
  when :retry
    show_retry(event.attempt, event.max_attempts, event.delay)
  when :tool_started
    mark_tool_running(event.tool_call)
  when :tool_result
    settle_tool(event.tool_call, failed: event.tool_error)
  when :approval_needed
    request_human_decision(event.tool_call)
  when :done, :error
    settle_provider_turn(event.message)
  end
end
```

`:tool_started` and handler progress originate on tool worker threads. Calls
within one Agent are serialized before reaching the subscriber, but background
children can emit alongside the parent. A custom sink must be thread-safe.

`Mistri::Sinks::Coalesced` is origin-aware and thread-safe. It merges bursts of
text, thinking, and tool-argument deltas by event type, content index, and
origin, then flushes before any other event:

```ruby
raw = Mistri::Sinks::SSE.new(io)
sink = Mistri::Sinks::Coalesced.new(raw, interval: 0.05)

agent.run(input, &sink)
```

`Mistri::Sinks::SSE` accepts any object with `write` and optionally `flush`.
`Mistri::Sinks::ActionCable` resolves Action Cable lazily or accepts an explicit
broadcaster. None of these require a Railtie.

Subscriber callbacks are not an error-isolation boundary. An exception can
abort an operation and, after a handler starts, create the same unknown-outcome
gap as a process crash. Do not raise intentionally from a sink; keep it small,
observable, thread-safe, and independently retryable where possible.

## Stopping

`Mistri::AbortSignal` is an in-process, thread-safe, one-way latch:

```ruby
signal = Mistri::AbortSignal.new

runner = Thread.new do
  agent.run("Draft a long report.", signal: signal)
end

signal.abort!("user cancelled")
runner.join
```

The provider transport registers a callback that closes an in-flight socket,
so abort does not wait for the read timeout. The Agent checks the signal at safe
boundaries and persists a replay-valid partial turn.

Tool handlers are application code. A handler doing long work should inspect
`context.signal&.aborted?` at safe points or arrange its own cancellable I/O.
Cancellation is cooperative; Mistri does not kill arbitrary handler code.

The signal object cannot be shared across processes. Cross-process child stop
uses a shared lock adapter and a cooperative flag, as described in
[Sub-agent lock adapters](sub-agents.md#lock-adapters). Top-level session runner
coordination remains host policy.

## Budgets

Budgets are opt-in:

```ruby
budget = Mistri::Budget.new(
  turns: 20,
  tokens: 500_000,
  cost_usd: 5.00,
  wall_clock: 300,
)
```

Limits are checked between model-visible turns. A turn already in progress,
including its retry attempts, completes before the next check. Every budget is
therefore a soft ceiling and may exceed its configured value by one turn.

### Cost budgets

Unknown price is not zero. Constructing a cost-budgeted Agent requires a
catalogued model, a list-priced origin, and deterministic standard-tier policy.

Anthropic and OpenAI require the tier explicitly:

```ruby
anthropic = Mistri.agent(
  "claude-opus-4-8",
  budget: Mistri::Budget.new(cost_usd: 5.00),
  provider_options: { service_tier: "standard_only" },
)

openai = Mistri.agent(
  "gpt-5.6-terra",
  budget: Mistri::Budget.new(cost_usd: 5.00),
  provider_options: { service_tier: "default" },
)
```

Gemini's omitted tier is standard by contract. A reported Flex or Priority
tier remains unpriced by the standard catalog.

If a cost-budgeted request returns usage that cannot be priced, Mistri raises
`Mistri::BudgetError` and does not retry under false certainty. The exception
exposes `usage` and `provider_message`; the Session also records an
`unpriced_attempt` entry for reconciliation.

`result.usage.cost.known?` distinguishes known accounting from an unavailable
estimate. Dollar values use published standard paid direct-API list prices
embedded and versioned with the installed gem; they are not fetched live.
Contracted pricing, regional uplifts, taxes, and separately billed provider
tools are outside the estimate. Gemini free-tier usage is conservatively valued
at the paid rate.

Custom provider origins disable catalog pricing by default. Pass
`catalog_pricing: true` only when that route bills exactly the same published
rates. This flag never changes service-tier policy.

## Inbound response limits

Provider and MCP JSON bodies, individual SSE lines, and stdio records default
to 8 MiB per record. A stream can exceed 8 MiB in total while every atomic
record remains within the boundary.

Successful bodies are counted while reading. Declared oversized bodies fail
before their body is read. Error responses retain at most a 500-byte valid UTF-8
preview. Requests use identity encoding so compressed expansion cannot evade
the limit.

Completed SSE JSON records receive a bounded structural scan before parsing.
Fragmented Anthropic and OpenAI tool arguments also carry an aggregate 8 MiB
limit across deltas; their partial preview refreshes on a bounded schedule while
raw delta events continue.

Set `max_record_bytes:` through `provider_options:` only after deciding the
larger trusted boundary is acceptable:

```ruby
agent = Mistri.agent(
  "gemini-3.1-pro-preview",
  provider_options: { max_record_bytes: 16 * 1024 * 1024 },
)
```

The byte boundary is configurable. Fixed structural ceilings protect the JSON
allocation shape and are not raised by that option.

## Provider input and options

Images are immutable content blocks:

```ruby
photo = Mistri::Content::Image.from_bytes(
  File.binread("chart.png"),
  mime_type: "image/png",
)

agent.run("What trend does this chart show?", images: [photo])
```

`from_data_uri` accepts the `data:<mime>;base64,<data>` shape commonly produced
by a canvas or upload. The host still owns media allowlists, decoded-size
limits, and content inspection.

Provider constructor settings go through `provider_options:`:

```ruby
Mistri.agent(
  "gpt-5.6",
  provider_options: { reasoning: { summary: "auto" } },
)

Mistri.agent(
  "claude-opus-4-8",
  provider_options: { cache: false },
)
```

Provider-specific per-turn overrides belong on a directly constructed
provider's `stream` contract. The Agent intentionally exposes a stable common
loop rather than mirroring every provider option as a top-level keyword.

## Custom providers

A provider used by `Mistri::Agent` exposes a model ID and responds to `stream`:

```ruby
message = provider.stream(
  messages: messages,
  system: system,
  tools: tool_specs,
  signal: signal,
  **overrides,
) do |event|
  # Mistri::Event instances
end
```

`provider.model` is required by default compaction and cost-policy checks.
Disable compaction explicitly only when a custom provider cannot describe a
model context window.

It returns an assistant `Mistri::Message`. A completed tool call must be a
`Mistri::ToolCall` with:

- a non-empty UTF-8 String ID unique for new calls in the Session;
- a non-empty UTF-8 String name;
- an owned JSON object for valid arguments, or `arguments_error` for malformed
  encoded input;
- non-empty UTF-8 signature and provider call ID strings when present.

A malformed completed envelope rejects the whole provider attempt before the
assistant message persists or any sibling tool runs. Do not invent missing IDs
inside the Agent; the provider owns its wire correlation.

Custom providers may return `native_output_schema(schema)` when they can enforce
the requested task contract. Returning nil leaves the prompt and local
validation path intact.

To support cost budgets, return true from `prices_usage?` and attach a known
cost to every response, commonly with `Mistri::Usage#with_cost`. Missing or
partial pricing then fails closed at runtime.

Study `Mistri::Providers::Fake` for a hermetic implementation and the built-in
assemblers for strict streaming lifecycle behavior.

## Testing strategy

The default suite uses the Fake provider, recorded wire fixtures, local stub
servers, and no network:

```console
$ bundle exec rake test
$ bundle exec rubocop
```

Gated live tests exercise exact provider regressions when keys are present:

```console
$ MISTRI_LIVE=1 bundle exec rake test
```

The integration harness runs critical end-to-end scenarios across an Anthropic,
OpenAI, and Gemini model by default:

```console
$ bundle exec rake integration
$ MISTRI_INTEGRATION_MODELS=claude-opus-4-8 bundle exec rake integration
```

Keys load from the gitignored `.env.development.local`. A missing key skips that
provider; inspect the test output before claiming a full three-provider run.

## Related guides

- [Tool contracts](tool-contracts.md)
- [Sessions and control](sessions.md)
- [Sub-agents](sub-agents.md)
- [MCP](mcp.md)
- [Upgrading](../UPGRADING.md)
