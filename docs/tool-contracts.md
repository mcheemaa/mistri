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

agent = Mistri.agent("claude-opus-4-8", tools: tools, before_tool: before_tool)
```

The hook also runs when an approved call resumes, so long-lived approval does
not bypass current authorization. A raised hook error blocks conservatively.

`after_tool` receives `(call, result, context)` and may return a replacement
result. Returning nil keeps the original. If the original result is an error,
rewriting its text cannot relabel it as success.

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

## Provider-executed web search

`Mistri.web_search` enables the provider's own hosted search. It rides the
`tools:` array next to ordinary tools, but nothing about the execution
boundary above applies: the provider runs the search on its side, the loop
never executes anything, and no result crosses the tool-result boundary.

```ruby
agent = Mistri.agent("claude-opus-4-8", tools: [Mistri.web_search])
result = agent.run("What is the current stable Ruby version? One sentence.")
```

Each provider maps it to its native mechanism: Anthropic's `web_search` server
tool, the OpenAI Responses `web_search` tool, and Gemini's Google Search
grounding. Search activity streams as `server_tool_call_start/_end` and
`server_tool_result_start/_end` events, and lands on the assistant message as
`Content::ServerToolCall` and `Content::ServerToolResult` blocks. The blocks
persist in the session and replay verbatim, but only to the provider that
produced them; on any other provider they drop from the history, like
unsigned thinking.

Boundaries to know: searches bill on the provider's side and do not appear in
`Usage`; a failed search arrives as model-visible content the model reacts
to, never as an exception; and Gemini reports grounding as response metadata,
so it folds into one `ServerToolResult` block and never replays.

## Related guides

- [Sessions and control](sessions.md)
- [MCP](mcp.md)
- [Reliability](reliability.md)
- [Upgrading](../UPGRADING.md)
