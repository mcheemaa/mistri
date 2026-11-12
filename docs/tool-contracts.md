# Tool contracts

A Mistri tool is application code exposed to model output. Treat that boundary
like an HTTP endpoint: declare what it accepts, authorize the acting context,
and make writes idempotent or reconcilable.

This guide covers local tools. Remote MCP tools cross the same execution
boundary; see [MCP](mcp.md) for the additional server contract.

## Define a tool

```ruby
charge_card = Mistri::Tool.define(
  "charge_card", "Charges a saved payment method.",
  schema: lambda {
    string :payment_method_id, "Saved payment method ID", required: true
    number :amount_usd, "Amount in US dollars", required: true
  },
  needs_approval: ->(args) { args.fetch("amount_usd") >= 500 },
) do |args, context|
  Payments.charge!(
    customer: context.app.fetch(:customer),
    payment_method_id: args.fetch("payment_method_id"),
    amount_usd: args.fetch("amount_usd"),
  )
end
```

The handler may accept only `args`, or `args` and `context`. `context.app` is
the object passed as `Mistri.agent(context:)`; it is the usual place for the
acting user, tenant, or request-scoped authorization context.

Handlers may return:

- a String, delivered to the model as text;
- a Hash, number, boolean, nil, or data Array, serialized as JSON or empty text;
- an Array made only of Strings and Mistri content blocks, delivered as
  multiple content blocks, including images;
- `Mistri::ToolResult`, which separates model content, host-only UI, and an
  explicit failure fact.

## The execution boundary

A completed model call moves through these phases in order:

1. Mistri verifies the provider's call envelope and pairing metadata.
2. The argument value is copied into bounded, immutable JSON owned by Mistri.
3. The tool's explicit `argument_normalizer`, if any, runs once.
4. Core schema validation and the tool's host validator run.
5. `before_tool` evaluates current application policy.
6. `needs_approval` decides whether the prepared call must park.
7. A free call emits `:tool_started` and invokes the handler.
8. `after_tool` may rewrite the result, which then persists and emits
   `:tool_result`.

Malformed or invalid calls do not reach policy or execution. The model receives
a bounded error result it can correct, while valid sibling calls in the same
turn continue. Results settle in the model's call order even when handlers run
concurrently.

An approved call is revalidated against the current tool definition and passes
through `before_tool` again on `resume`. Its normalizer and approval predicate
do not run again: the human approved the already prepared arguments.

## Schema forms

The DSL builds a JSON Schema 2020-12 object:

```ruby
search = Mistri::Tool.define("search", "Searches products.", schema: lambda {
  string :query, "Search text", required: true
  integer :limit, "Maximum result count"
  array :tags, "Required tags", items: { type: "string" }
  object :filters, "Structured filters" do
    string :country, "ISO country code"
    boolean :in_stock, "Only products in stock"
  end
}) do |args|
  filters = args.fetch("filters", {})
  Catalog.search(
    query: args.fetch("query"),
    limit: args["limit"],
    tags: args.fetch("tags", []),
    country: filters["country"],
    in_stock: filters["in_stock"],
  )
end
```

Use `input_schema:` for a raw schema:

```ruby
schema = {
  type: "object",
  properties: {
    "invoice_id" => { type: "string" },
  },
  required: ["invoice_id"],
  additionalProperties: false,
}

Mistri::Tool.define("pay_invoice", "Pays one invoice.", input_schema: schema) do |args|
  Invoices.pay!(args.fetch("invoice_id"))
end
```

The root must be an object schema. `Tool.define` without `schema:` or
`input_schema:` creates a closed no-argument tool; model-supplied fields are
rejected.

### Open and closed objects

Supplied object schemas follow JSON Schema's default-open semantics. Declared
properties do not automatically reject additional keys. Extract the fields you
intend to use rather than mass-assigning the entire model hash.

Set `additionalProperties: false` in a raw schema when extra keys must fail.

A nested object declared without a block is intentionally freeform:

```ruby
object :config, "Chart-library configuration", required: true
```

It accepts any JSON object, including `{}`. This is useful when Mistri should
not prescribe keys owned by another library. A bare top-level `Schema.build`
raises because it communicates no argument contract.

Freeform objects cannot become strict constrained output without changing their
meaning. `Schema.strict` and task planning reject that shape instead of silently
narrowing it to `{}`.

### Portable validation subset

Mistri's zero-dependency validator enforces:

- JSON `type`, including type unions;
- `enum`;
- `required` and declared `properties`;
- one-schema array `items`;
- tuple array `prefixItems`;
- boolean schemas;
- boolean or schema-valued `additionalProperties`.

Other standard keywords remain provider-facing generation guidance unless a
complete validator is supplied. Examples include `minimum`, `pattern`,
`format`, length constraints, and applicators such as `anyOf`.

An argument-applicable, non-empty `patternProperties` requires complete
authority because approximating its key and value interactions would be
unsafe. External references are not resolved.

Task output is stricter than tool input: task planning rejects assertions that
local validation cannot guarantee. A task promises a validated value; a tool
server can still enforce its own broader contract after Mistri's local subset.

## Host validation

Use `argument_validator:` for domain rules that supplement core validation:

```ruby
invoice = Mistri::Tool.define(
  "pay_invoice", "Pays an approved invoice.",
  input_schema: invoice_schema,
  argument_validator: lambda { |args, _schema|
    if args.fetch("invoice_id").start_with?("inv_")
      []
    else
      ["$.invoice_id must identify an invoice"]
    end
  },
) do |args|
  Invoices.pay!(args.fetch("invoice_id"))
end
```

The validator receives the deeply frozen arguments and canonical schema. It
must return an Array of Strings. Core validation runs first and cannot be
weakened.

Use `complete_argument_validator:` only when the host validator implements the
whole schema, including interactions outside Mistri's portable subset. It has
the same `(args, schema)` signature and is mutually exclusive with
`argument_validator:`.

Validator errors are sent back to the model. Describe the expected contract;
do not echo received secrets or field values.

## Explicit normalization

Mistri does not coerce model input. If a tool intentionally accepts a legacy
alias or representation, declare that compatibility policy on the tool:

```ruby
normalizer = lambda do |args|
  next args unless args.key?("account")
  raise ArgumentError, "choose account or account_id" if args.key?("account_id")

  normalized = args.dup
  normalized["account_id"] = normalized.delete("account")
  normalized
end

tool = Mistri::Tool.define(
  "lookup_account", "Looks up one account.",
  schema: -> { string :account_id, "Account ID", required: true },
  argument_normalizer: normalizer,
) do |args|
  Accounts.find(args.fetch("account_id"))
end
```

The normalizer must return a Hash and should be pure, deterministic, and
idempotent. Its output is what validation, policy, approval, and the handler
see.

Direct `Tool#call` is a trusted host invocation. It applies the normalizer for
compatibility, but the Agent's model-input ownership and validation boundary is
not involved.

## Policy hooks

`before_tool` can block a call with a model-readable reason:

```ruby
before_tool = lambda do |call, context|
  next "customer cannot perform this action" unless context.app.fetch(:customer).active?
  next "currency is not enabled" unless call.arguments.fetch("currency") == "USD"
end

agent = Mistri.agent("claude-opus-5-5", tools: tools, before_tool: before_tool)
```

The hook also runs when an approved call resumes, so long-lived approval does
not bypass current authorization. A raised hook error blocks conservatively.

`after_tool` receives `(call, result, context)` and may return a replacement
result. Returning nil keeps the original. If the original result is an error,
rewriting its text cannot relabel it as success. Text returned for a result
that [loads tools](#tools-on-demand) replaces what the model reads and the
tools still load; return a `Mistri::ToolResult` to decide the loads yourself.

## Results and UI

Use `Mistri::ToolResult` when the model and host need different views:

```ruby
Mistri::Tool.define("edit_page", "Applies a page edit.", schema: lambda {
  object :changes, "Page changes", required: true
}) do |args|
  page = Pages.apply(args.fetch("changes"))
  Mistri::ToolResult.new(
    content: "Saved the page.",
    ui: { "html" => page.html, "revision" => page.lock_version },
  )
end
```

`ui` persists on the tool message and appears on the `:tool_result` event, but
is never sent to a provider.

Non-text tool-result content remains provider-neutral in the Session. Anthropic
can receive image blocks in a tool result. The current OpenAI and Gemini
function-result serializers have no such encoding and send an explicit
non-text-omission marker alongside the text instead.

Return `error: true` for an expected failure the model should handle:

```ruby
account || Mistri::ToolResult.new(
  content: "Account not found.",
  error: true,
)
```

Mistri also marks unknown tools, validation and policy rejection, handler
exceptions, timeouts, pre-invocation interruption, failed result hooks,
crash-healed calls, and MCP `isError` results. Human denial is an expected
control outcome, not an execution failure.

`event.tool_error` and `event.message.tool_error?` expose the fact without
parsing prose. A legacy persisted result without the field remains unknown;
Mistri does not infer historical success from text.

An error flag does not make a replay safe. A handler may have committed a write
before raising or timing out. Mistri never mechanically replays the same call
because it is marked failed, but the model may issue another call. The host
still owns idempotency and reconciliation.

## Tools on demand

A tool definition costs input tokens on every model round, and a host that
bridges a few MCP servers can hold hundreds of them. Mark a tool
`deferred: true` and the model is not shown it until it is needed:

```ruby
refund = Mistri::Tool.define(
  "refund_charge", "Gives a customer their money back.",
  deferred: true,
  schema: -> { string :charge, "Charge id", required: true },
) { |args| Billing.refund(args.fetch("charge")) }
tracker = Mistri::MCP.tools(client, prefix: "tracker", deferred: true)

agent = Mistri.agent("claude-haiku-5-5", tools: [lookup_order, refund, *tracker])
```

An agent that holds a deferred tool adds one of its own, `tool_search`. The
model asks it in words for what it needs to do. The search ranks the deferred
tools by their name, their description and the names and descriptions of their
parameters, loads the best matches (five by default, twenty at most) and
answers with their names. From its next step the model calls them like any
other tool. One load also holds no more than 20 KB of definitions; of 303
definitions measured on 22 public servers, nine in ten were under 2.2 KB. A
first match larger than that still loads, alone. When the size bound stops a
load before its count, the result states that more tools match, and the next
search loads them.

The deferred tools are listed in the conversation. With its first request an
agent appends a reminder to the session, after the user's message, that names
every deferred tool. It appends one again when the list has changed, and
after a compaction that summarized the previous one. An agent that holds no
deferred tool, on a session that has a list, appends one that states so. Past
20 KB of names the reminder gives the number of tools under each name prefix
instead, up to 20 KB of prefixes, and one count for the rest. So give a server
a prefix that describes it. The definition of `tool_search` is the same
whatever the list holds. Connecting a server therefore changes neither the
tools nor the system prompt of a request, and the prompt cache holds.

The reminder is a user message whose `reminder` is `"deferred_tools"`. The
user did not write it, so a host that shows a conversation to a person hides
a message with `reminder` set. A compaction does not summarize it.

A query that is a tool's name loads that tool and no other. The same applies
to the name without its prefix and to the words of the name, so `create issue`
loads `tracker__create_issue`. The model can name several tools in one query:
`select:` followed by their names, separated by commas, or their full names
separated by spaces. The result lists the names that match no tool. A name
that many tools share, such as `list` under thirty prefixes, loads no more
than the limit, and the result gives the number that remain. When the query
gives no limit, a search loads five tools, or as many as the query names
when that is more, up to twenty.

A tool that is already loaded is not loaded again. The result states that it
is loaded and names it in its own `loads`, so the tool stays loaded while
either result is in the history. Its definition is still sent once. The
search continues with the next matches, so a repeated search loads tools
further down the ranking. A search also treats a tool as loaded once another
search of the same turn has selected it, so two searches in one turn do not
load the same tool. If an `after_tool` hook cancels a load and no other
result names the tool, a search loads it again from the next request.

Any other query is a word search. It matches the words of a name, a
description or a parameter, not their meaning. A run of Han, kana or Hangul
characters, which often has no spaces between its words, is matched by pairs
of characters, and by one character when the query is one. In words,
half-width and full-width forms match each other; a name is matched as it is
written. Other scripts written without spaces match poorly. A query is read
up to 500 characters.

A load is stored with the tool result that names it. A later run on the same
session offers the same tools with no new search. A tool is loaded while a
successful result that names it is in the history. After a compaction that
summarizes every such result of a tool, the summary is followed by the names
of the tools loaded before it.
The message states that their definitions are no longer in the model's
context and instructs it to load the ones it needs again by name. A call to
one of them without a new load still runs, after the usual argument check:
the model received that definition when it loaded the tool.

Any tool can load deferred tools with its result:

```ruby
Mistri::ToolResult.new(
  content: "The tracker is open.",
  loads: %w[tracker__create_issue tracker__list_issues],
)
```

A name that is not a deferred tool of this agent is ignored, and a result
marked `error: true` loads nothing.

A deferred tool is still one of the agent's tools. Its approval gate, the
argument check, `before_tool` and `after_tool` apply when it runs. A call to
one that no result has loaded does not run: the model has the name and not
the schema, so its arguments would be a guess. The error result instructs the
model to load the tool with `tool_search` and call it again. A call that
waited for approval was loaded when the model made it, and it is not checked
again when the run resumes. Keep the few tools every conversation needs out
of deferral, so the model does not search for them, and do not name a
deferred tool in a system prompt as if it were already loaded. A
host tool named `tool_search` beside a deferred tool is a duplicate name and
fails Agent construction.

How a loaded tool reaches the model depends on the provider, and a host does
not choose:

- Anthropic receives a deferred definition from the request whose result
  loads it, marked `defer_loading` so that it stays out of the prompt, and
  that result carries a reference to it. A later result that names the same
  tool carries none, because every reference adds the definition to the
  prompt again. The prompt cache holds across a load. One reserved definition, `mistri_deferred_tools`, is sent the same
  way from the first request, because the first deferred definition in a
  conversation would otherwise rebuild the cache once. No result references
  it, so it never enters the prompt. No result can load it, and a tool of
  that name beside deferred tools fails the request before it is sent. The
  result's own text follows the tool results of that turn. This form is used
  on the official origin. Another origin is treated like the last provider
  below unless the host sets `defers_tools: true`.
- OpenAI keeps the request's own tools as they are, and a result that loads
  tools is followed by an item in the input that makes them callable from
  that point on. The prompt cache holds across a load here too. This is used
  on the official origin, for the models OpenAI documents it for: gpt-5.4 and
  later, the nano models aside. An older model, a nano model and another
  origin are treated like the provider below unless the host sets
  `defers_tools:`.
- Gemini, and any other provider, is sent the tools that are not deferred,
  then the loaded ones in the order they were loaded.

The growing list costs more for each load than the two forms above. A load
changes the request's tools, so the prompt cache is built again from the
start. On Anthropic's API a changed tool list also makes the thinking of
earlier turns invalid: the request after a load is refused on the models that
check it, unless the host set
`block_binding: { prefix_mismatch_behavior: "drop_block" }`, and then that
thinking is dropped. So a host that reaches Anthropic or OpenAI through a
gateway that forwards requests unchanged sets `defers_tools: true`, which
selects the form that keeps the cached prefix across a load:

```ruby
Mistri.agent("claude-opus-5-5", tools: tools,
             provider_options: { origin: "https://gateway.example", defers_tools: true })
```

`defers_tools: false` selects the growing list on the official origin.

What it costs in the process is small. Building an agent with deferred tools
costs what a flat list costs. The search index is built once, on an agent's
first search, from each deferred tool's description and schema. Building a
request adds two passes over the history, one that collects the loaded names
and one that finds the newest reminder with the list of deferred tools, and
on OpenAI one pass over the loaded definitions to index them by name.

On the wire no request carries the definition of a deferred tool until a
result loads it, on any provider.

A provider of your own is sent the growing tool list. To hold definitions
back itself it answers `defers_tools?` with true, and `stream` is then given
the loaded deferred definitions as `deferred_tools:` beside `tools:`.

## Hand off the turn

`ends_turn: true` ends the run after the tool executes instead of asking the
model for another response. This is useful for `ask_user`, escalation, or a
structural handoff:

```ruby
ask_user = Mistri::Tool.define(
  "ask_user", "Asks the human and waits.",
  ends_turn: true,
  schema: -> { string :question, "Question", required: true },
) do |_args|
  "Question presented to the user."
end
```

`result.handed_off?` reports that the model's floor moved away. It does not
claim the tool succeeded; inspect the tool result separately. The human answer
arrives as the next `run` input.

## Resource limits

Completed arguments are bounded at 8 MiB, 64 levels, 10,000 JSON nodes, and 64
KiB per numeric token. Encoded Anthropic and OpenAI arguments receive a linear
lexical pass before JSON parsing. Gemini's enclosing SSE record receives the
same structural preflight before its argument object is canonicalized.

These are safety boundaries, not business validation. Keep tool schemas narrow,
validate domain rules explicitly, and return references rather than embedding
unbounded data in a tool call.

## Related guides

- [Sessions and control](sessions.md)
- [MCP](mcp.md)
- [Reliability](reliability.md)
- [Upgrading](../UPGRADING.md)
