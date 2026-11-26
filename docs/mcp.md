# Model Context Protocol

Mistri can turn tools from a Model Context Protocol server into ordinary local
tools. The Agent's validation, approval, event, session, and result contracts
then apply to the remote call.

The built-in client supports Streamable HTTP and stdio with no additional gem
dependency. `Mistri::MCP.tools` is duck-typed, so a different client can bridge
when it responds to `tools` and `call_tool(name, arguments)` with the documented
hash shapes.

## Transports

### Streamable HTTP

```ruby
client = Mistri::MCP::Client.new(
  url: "https://mcp.linear.app/mcp",
  token: -> { connection.bearer_token },
)

tools = Mistri::MCP.tools(
  client,
  prefix: "linear",
  allow: %w[search_issues get_issue create_issue],
  gates: { "create_issue" => true },
)

agent = Mistri.agent("claude-opus-5-5", tools: tools)
```

`token:` accepts a String or callable. The callable resolves for every request.
After a 401, Mistri resolves it once more and retries once, so the host can put
refresh behavior behind the callable.

A callable that takes `refused:` is given the token the server just refused,
when it is asked again after a 401. It can then replace that token only when
it is still the stored one, which matters when several processes share a
connection:

```ruby
token: ->(refused: nil) { connection.bearer_token(refused: refused) }
```

After a 403 whose challenge says `insufficient_scope`, Mistri does not ask
again: a new token of the same sign-in has the same scope. See
[More scope](#more-scope).

Use `headers:` for fixed application headers. Mistri copies them at client
construction and rejects framing plus MCP session and protocol headers. A fixed
Authorization header is permitted; when `token:` is supplied, Mistri owns
Bearer authorization and overwrites it.

One Client serializes its requests. Parallel Agent tool calls against the same
client queue rather than interleave. Use distinct clients only when the server
and host policy allow true parallel connections.

A server answers a request with a JSON body or with an SSE stream. A call
returns when its answer arrives. Most servers end the stream with the answer,
and the connection is then kept for the next request. A stream that is still
open a tenth of a second after the answer is left, and its connection is
closed.

A server may end a stream before the answer and expect the client back. When
an event of that stream carried an id, the client waits the `retry` the server
named, or one second, and asks for the rest with a GET and `Last-Event-ID`. It
does so once, and not when the wait is longer than `read_timeout`. The call is
never sent again.

An HTTP status that refuses a request is raised as the transport's error for
that status, such as `Mistri::ServerError`, with its `status` and `body`. The
message names the MCP server: `the MCP server answered HTTP 400`, followed by
the message of a JSON-RPC error when the body holds one.

### Stdio

```ruby
browser = Mistri::MCP::Client.new(
  command: [
    "npx", "-y", "@playwright/mcp@latest",
    "--browser", "chrome", "--headless",
  ],
  read_timeout: 180,
)

tools = Mistri::MCP.tools(
  browser,
  prefix: "web",
  allow: %w[browser_navigate browser_snapshot],
)
```

`command:` is an argument array, not a shell string. Mistri writes one JSON-RPC
object per line and bounds the complete record read, including the time after
its first byte.

A line on the server's stdout that is not JSON is skipped. It is written to the
host's standard error, where the server's own standard error already goes, and
the wait for the message goes on.

The server does not inherit the host's environment, which holds provider keys
and other secrets. It starts with `env:` and these variables from the host
process:

| Purpose | Variables |
| --- | --- |
| Identity and programs | `HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `TERM` |
| RubyGems paths | `GEM_HOME`, `GEM_PATH` |
| Locale, time, and temp files | `LANG`, `LC_ALL`, `LC_CTYPE`, `TZ`, `TMPDIR` |
| CA bundles | `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` |

Pass anything else through `env:`. It also overrides the variables above. For
example, `env: { "API_KEY" => key, **ENV.slice("HTTPS_PROXY", "NO_PROXY") }`
gives the server a credential and the host's proxy settings.

This is not a sandbox. The server runs as the host's user and can read the
host's files.

`@latest` is convenient for local exploration. Pin a reviewed package version
in an application or deployment so the executable does not change without a
code review.

Call `client.close` when a long-lived host is finished. For stdio, it closes the
Call `client.close` when a long-lived host is finished. For stdio, it closes the
server's input and waits half a second for the server to end. A server that is
still running is sent SIGTERM, and SIGKILL one second after that. For HTTP, it
sends a DELETE with the session id, as the spec asks, on a connection that
waits five seconds at most, and forgets the session whatever the server
answers. It sends the token it last sent and does not ask the host for a new
one. The discovered tool cache remains available.
`call_tool` or `tools(refresh: true)` performs a fresh handshake when needed.
### Requests from a server

In the older form of the protocol a server may send its own requests while a
call waits for its answer. The client declares no capability, so it answers `ping` with an empty result and
refuses any other request with JSON-RPC error -32601. Over Streamable HTTP the
reply is a POST of its own, on a second connection that waits five seconds at
most, because the first is taken by the stream of the call.

A request is never taken for the answer to a call, whatever its id. An answer
is matched by the id of its call, also when the server sends that id back as a
string.

### What the host is told

```ruby
client = Mistri::MCP::Client.new(
  url: server_url,
  on_notification: ->(method, params) { Rails.logger.info("#{method} #{params}") },
  progress: true,
)
```

`on_notification:` is called with the method and the params of each
notification the server sends while the client reads: a changed tool list, a
progress notice, a log line. It runs inside the call, so it must not use the
client. What it raises is written to standard error with the prefix
`mistri:`, and the call goes on. The kept tool list is not changed by a
notice. The host lists again with `refresh: true` when it decides to.

A notice reaches the host when it arrives on a stream the client reads. Over
stdio that is the next call at the latest. A notice that a server sends on a
stream of its own, outside any call, is not read.

`progress: true` asks for progress with each tool call, by a token that is the
call's own request id. Each progress notice is a message, so a call that
reports progress is not ended by `read_timeout`. The limit of the bridged
tool still holds.

`client.state` is `:idle` before anything was asked, `:connected` once the
server answered, `:needs_sign_in` after it refused to authorize, and `:failed`
when it could not be reached, its connection broke, a local server could not
be started, or it answered with an HTTP error. `client.failure` holds the
reason. A call that timed out, an answer over a limit and an error the server
answered with leave both as they were. The next answer makes the state
`:connected` again.

A bridged tool whose server cannot be used tells the model so, and names the
server by the `prefix:` the host gave it: `No connection to the MCP server
"tracker" could be established, so tracker__search did not run`, or `the MCP
server "tracker" needs a sign-in before its tools can be used`. A call to a
server whose connection could not be opened did not run, and is not reported
as one that may have completed.

### Protocol revisions

The client speaks two forms of the protocol. In the form of 2026-07-28 there
is no handshake and no session: each request carries the revision, the
client's name and its capabilities. In the older form, 2025-11-25 and three
revisions before it, a session opens with `initialize`.

Before its first request the client asks the server which revisions it speaks,
with `server/discover`. A server that offers 2026-07-28 is used in that form.
An older server does not know the request, and whatever it answers that is not
an error of the 2026-07-28 revision leads to the handshake. On stdio so does no
answer within five seconds, or within `read_timeout` when that is shorter. A
refusal to authorize, a server error and a lost connection say nothing about
the revision and are raised as they are.

The answer is kept for the life of the client. `client.listing` holds it as
`"protocolVersion"`, so a client built from a stored listing asks nothing: in
the form of 2026-07-28 its first request is the call itself.

In the form of 2026-07-28:

- A request from the server gets no reply. The revision allows neither.
- Over HTTP a call that is given up is cancelled by its closed stream, with no
  notification, and a stream that ended early is not asked for again.
- Over HTTP each request repeats its method in `Mcp-Method`, a call repeats
  its tool in `Mcp-Name`, and each parameter that a tool marks with
  `x-mcp-header` is repeated in `Mcp-Param-*`. A direct `call_tool` on a
  client that holds no listing lists the tools first, to learn the marks. A
  tool whose marks break the rules of the revision is left out of the list and
  named in a warning on standard error.
- `close` sends no DELETE, because there is no session.
- A server may answer a call by asking for input. The client declares no
  capability to give any, so such a call ends as a tool error that says so,
  with the server's own message. A result that asks for nothing and carries
  `requestState` is sent again with it, three times at most.
- A header that does not match the request is raised as the server's refusal.
  The spec suggests listing the tools again. The kept listing is the host's
  pin, so the host decides.

## Tool discovery

`client.tools` performs the handshake and follows `tools/list` pagination once,
then caches the result. Use `client.tools(refresh: true)` when the host decides
to accept a changed toolset.

Discovery defaults to at most 100 pages and 10,000 tools:

```ruby
client = Mistri::MCP::Client.new(
  url: server_url,
  max_tool_pages: 20,
  max_tools: 2_000,
)
```

Repeated cursors, malformed collections, and exceeded limits raise instead of
looping or allocating without bound.

### Storing a server's listing

Listing a server's tools takes a connection, and a stdio server must be
started first. With many servers that is too slow to repeat each time an
agent is built. `client.listing` returns the server's tools, its
`instructions` when it sent any, and the revision it speaks, as plain JSON.
Store it, and pass it to the clients built later:

```ruby
# Once, in a job.
kept = Mistri::MCP::Client.new(url: server_url, token: token).listing
store.write("tracker", kept)

# Each time an agent is built.
client = Mistri::MCP::Client.new(url: server_url, token: token,
                                 listing: store.read("tracker"))
tools = Mistri::MCP.tools(client, prefix: "tracker", deferred: true)
```

A client built with `listing:` returns `tools` and `instructions` from it and
sends no request. It connects when a tool is first called, and a stdio server
is not started before that. Building an agent over many servers then opens no
connection.

`client.listing(refresh: true)` lists the server again. When to do that is
the host's decision. Until then a tool the server has removed fails when it
is called, and a tool it has added is not offered.

### Server instructions

A server may send `instructions` in its initialize result: text on how to use
its tools. `client.instructions` returns it, and `Mistri::MCP.tools` sets it
on every tool it bridges, as `Tool#instructions`.

The text is the server's, and the host decides whether the model reads it,
and with what weight:

```ruby
Mistri::MCP.tools(client)                                  # the server's text
Mistri::MCP.tools(client, instructions: false)             # none
Mistri::MCP.tools(client, instructions: "Use for orders.") # the host's text
Mistri::MCP.tools(client, instructions_as: :user)          # as text of a user turn
```

An agent appends the instructions of every server to the conversation with
its first request, before the model chooses a tool, so they can guide the
choice. They are appended as one reminder, a system message of the
conversation whose `reminder` is `"tool_instructions"`. It holds one text
block for each server, which names that server's tools. A server's
instructions are cut at 2,000 bytes.

When the text blocks of all servers are more than 20,000 bytes together, the
instructions of a server whose tools are all deferred are appended with the
request after one of its tools is loaded. A server with a tool that is not
deferred is not delayed.

After a compaction that summarized them, the instructions are appended again
by the same rule.

The instructions are text from the server, and they are sent the way every
[reminder](tool-contracts.md#tools-on-demand) is: as a system message to an
Anthropic model that takes one in a conversation, as a developer message to
OpenAI, and otherwise as text of a user turn in a system-reminder block. Each
block names the tools it is about. A model gives such a message the weight of
your own instructions, so give a server's instructions the trust you give
that server.

`instructions_as: :user` gives a server's instructions less weight. They are
then sent as text of a user turn in a system-reminder block on every provider,
and never as a system or developer message. The reminder they are appended as
is `"tool_instructions_as_user"`.

### What else a server's text can do

A tool's description is text from the server that the model reads as guidance.
`Mistri::MCP.tools` cuts one at 4,096 characters and ends it with a line that
says so. `description_limit:` sets another number, and `nil` sets none. Of
350 definitions from 32 public servers the longest description has 3,674
characters.

A server marks a tool that only reads with `readOnlyHint`, and such a tool may
run beside others in a turn. Nothing checks the hint. `trust_hints: false`
means no tool is marked by it, only by the host's own `parallel:`.

A server can change a tool's definition after a person approved it.
`Mistri::MCP.digest(definition)` is the SHA-256 of a definition, as JSON with
the keys of every object in order, to keep with what was approved.
`Mistri::MCP.changes(kept, fresh)` takes two listings and returns the names of
the tools that were added, removed and changed:

```ruby
kept = store.read("tracker")
fresh = client.listing(refresh: true)
Mistri::MCP.changes(kept, fresh)
# => { "added" => [], "removed" => ["archive"], "changed" => ["search"] }
```

The client itself never replaces a kept listing. What to do with a changed
definition is the host's decision.

`Mistri::MCP.tools` filters remote names with `allow:` and `deny:`. `prefix:`
creates local names such as `linear__create_issue` while the remote call still
uses `create_issue`. Duplicate local tool names from two servers make Agent
construction fail; one server can never silently shadow another.

A local name is one every provider takes: letters, digits, underscores and
hyphens, 64 characters at most, not starting with a digit or a hyphen. A name
inside that set is not changed. MCP allows more, and so does a single provider
here and there, such as a dot on Gemini or a leading digit on Anthropic. Any
such name has its unsafe characters replaced and ends in eight characters of a
hash of the whole name, so `issues.list/open` becomes `issues_list_open_` and
the hash. The local name depends only on the prefix and the remote name: it is
the same in every run, whatever else the server lists.
`Mistri::MCP.local_name(remote, prefix)` gives it. A host that keeps names of
its own passes one with `bridge(client, definition, name:)`, and that name is
used as given.

A tool that cannot be bridged is left out, and the server's other tools stay
usable. That is a tool whose schema is not one Mistri can validate, one with
no name, one whose name or description is not UTF-8 text, a definition that
is not an object, and a tool whose local name is already taken by one listed
before it. Without a block the tool and the reason are written as a warning.
With one, the block is given what the server listed and the error, whose
message names the tool:

```ruby
tools = Mistri::MCP.tools(client, prefix: "tracker") do |_definition, error|
  connection.note_unusable(error.message)
end
```

What the server listed may not be an object, so check before reading a key
from it. A host that would sooner fail raises the error from the block.
`Mistri::MCP.bridge`, which takes one definition, still raises.

Two listed tools can get the same local name: the server lists one name twice,
lists a tool under the name Mistri made for another, or lists two long names
that share their first 55 characters and the short hash. The first one listed
keeps the name, so the order the server lists in decides which remote tool the
name calls. A host that stores local names or holds approvals across runs for
such a server should raise from the block.

`needs_approval:` gates every bridged tool. `gates:` sets policy by remote name
and overrides the shared default.

A bridged tool is marked `parallel` when its server lists it with
`readOnlyHint: true`, so it runs beside its marked neighbours in a turn. Any
other tool runs alone, in the order the model wrote, see
[The order of a turn's calls](tool-contracts.md#the-order-of-a-turns-calls).
The hint is the server's own word and nothing checks it. `parallel: false`
runs every tool of the server alone, `parallel: true` marks every tool, and a
hash by remote name sets single tools and leaves the rest to their hint. A
key that names no tool of the server raises `Mistri::ConfigurationError`. The
check is made against the tools the client has listed, so a server that drops
or renames that tool makes `MCP.tools` raise until the hash is changed. A
tool that only waits is read-only and still has to come before the call after
it, so set it to false:

```ruby
Mistri::MCP.tools(browser, parallel: { "browser_wait_for" => false })
```

One client sends its requests one at a time, so marked calls to one server
gain no time beside each other. They gain it beside other servers and other
marked tools.

`deferred: true` keeps a server's tools out of the model's sight until a search
loads them, so the definitions of a server with a long tool list are left out
of every request until one of its tools is needed. See
[Tools on demand](tool-contracts.md#tools-on-demand).

## Many servers

An agent can be given the tools of tens or hundreds of servers. Four things
keep that cheap, and each is a host decision that Mistri supports:

1. List each server once, in a job, and store the listing. Listing takes a
   connection for each server, so run the servers in parallel, wait a bounded
   time for all of them together, and let one failure leave the others:

   ```ruby
   clients = servers.transform_values { |url| Mistri::MCP::Client.new(url: url) }
   threads = clients.transform_values { |client| Thread.new { client.listing } }
   deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
   threads.each do |name, thread|
     left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
     store.write(name, thread.value) if thread.join([left, 0].max)
   rescue StandardError => e
     report(name, e)
   end
   ```

   A server that has not answered by then is left for the next run of the
   job. Its client is still `:idle`, and its thread ends by the client's own
   timeouts. `client.state` and `client.failure` say how each of the others
   ended. Mistri has no helper for this: it would start threads inside the
   host's process, and how many a process may hold, and for how long, is the
   host's decision.

2. Build the clients from the stored listings and bridge them once for the
   process. Bridging validates each schema, so it is the part worth doing
   once. Give every agent the same tool objects:

   ```ruby
   TOOLS = servers.flat_map do |name, url|
     listing = store.read(name)
     next [] unless listing

     client = Mistri::MCP::Client.new(url: url, listing: listing)
     Mistri::MCP.tools(client, prefix: name, deferred: true)
   end

   Mistri.agent("claude-haiku-5-5", tools: [*own_tools, *TOOLS])
   ```

   No connection is opened here. A server without a stored listing is left
   out, because a client built with `listing: nil` lists the server itself
   and connects to do so. A client connects when one of its tools is first
   called, and one client runs one call at a time. A host whose servers take
   a token for each user builds the clients of that user instead and keeps
   them for the user's session. After a listing is stored again, bridge that
   server again and replace its tools: a bridged tool keeps the definition
   it was built from.

3. Defer the tools, as above. The conversation then holds the names of the
   tools and the instructions of the servers, and a request carries the
   definition of a tool once a search has loaded it. When the instructions
   are more than 20,000 bytes together, a server's instructions are appended
   once one of its tools is loaded. See
   [Tools on demand](tool-contracts.md#tools-on-demand) and
   [Server instructions](#server-instructions).

4. Expect a server to be unreachable when it is first used. Whether a server
   can be reached is not known until one of its tools is called. If no
   connection can be established then, the tool's result states that it did
   not run, and the run continues.

Measured in an application with 22 servers and 303 tools: listing every
server took 21.6 seconds, once. After that, building the 22 clients took
34 ms, bridging 88 ms once for the process, and building an agent 0.5 ms. The
first search of the process took 33.5 ms and each later agent's first search
0.5 ms. Every request carried two tool definitions until a search loaded
more.

## Schema authority

Mistri validates the directly reachable portable subset described in
[Tool contracts](tool-contracts.md). The MCP server remains responsible for its
full advertised input schema, as required by the
[MCP tools contract](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).

Standard assertions outside Mistri's subset, such as `minimum`, `pattern`,
`format`, and `anyOf`, bridge as server-facing guidance. An unsupported
applicator subtree remains one guidance unit; Mistri does not partially enforce
inside it and imply a stronger guarantee.

When local policy depends on the full schema, supply a complete validator:

```ruby
tools = Mistri::MCP.tools(
  client,
  complete_argument_validator: lambda { |args, schema|
    host_json_schema_validator.errors(args, schema)
  },
)
```

The callback must implement the whole contract and return an Array of Strings.
Core ownership and its portable checks still run first.

An argument-applicable, non-empty `patternProperties` requires this explicit
complete authority. Same-document references can remain server guidance;
external references are rejected even with a complete validator so validation
never performs hidden file or network resolution.

An omitted `inputSchema` means a closed no-argument object. Explicit null,
non-object roots and malformed keyword shapes are configuration errors.

A schema may declare JSON Schema 2020-12 or draft-07, which is what common
schema generators emit. The two read the same for everything Mistri validates
locally, apart from three shapes that are refused for that one tool: `items`
as an array, a constraint beside a `$ref` (draft-07 ignores it and 2020-12
applies it), and `prefixItems` in a draft-07 schema. Every other rule on this
page holds for a draft-07 schema as well, so a shape draft-07 allows and
Mistri does not, such as an `$id` that is only a fragment, is still refused.
Any other declared dialect is a configuration error.

## Results and large data

Mistri maps MCP text, images, embedded resources, and `resource_link` into its
content model. `structuredContent` is used when no ordinary content is present
and is also retained in an error explanation. On a successful result containing
both fields, ordinary content currently wins and `structuredContent` is not
preserved.

`isError` becomes `ToolResult#error?` and remains structured in events and the
session. Anthropic receives native `is_error`; Gemini receives its error result
key. OpenAI's function-result shape has no error member, so it receives the same
explanatory content without a separate flag.

Large results should live behind a server or host resource. Return an MCP
`resource_link` and a concise description instead of embedding an unbounded
payload. Mistri renders the URI for the model and never fetches it automatically;
fetching credentials, retention, and access policy belong to the host or server.

## Response boundaries

Provider and MCP JSON bodies, individual SSE lines, and stdio records default
to an 8 MiB `max_record_bytes:` limit:

```ruby
client = Mistri::MCP::Client.new(
  url: trusted_server_url,
  max_record_bytes: 16 * 1024 * 1024,
)
```

The limit applies to one atomic record, not the lifetime of an SSE stream.
Successful HTTP bodies are counted incrementally, and a declared oversized body
fails before it is read. Requests use identity encoding so compressed expansion
cannot bypass the boundary.

Each completed MCP SSE JSON record is also checked before JSON parsing for 64
levels and 64 KiB per numeric token. The number of values in a record is not
counted, on a stream or on any other transport, so a server with a long tool
list answers the same however it replies.

Byte overflow raises `Mistri::ResponseTooLargeError`. Structural overflow raises
`Mistri::ResponseTooComplexError`. Both expose `kind` and `limit`.

Either failure closes the connection. Over HTTP the session is kept. Over stdio
the server is ended, and the next operation starts one and does the handshake
again.

### The time one call may take

`read_timeout:` is the wait for one message from the server, over stdio and
over HTTP. A comment that a server sends to keep a stream open is not a
message and does not start the wait again. When the wait passes, the client
sends `notifications/cancelled` for that request and stops waiting. It keeps
the stdio server, or the HTTP session. An answer that arrives later is
ignored. A list raises `Mistri::MCP::Error`. A tool call raises
`Mistri::AmbiguousDeliveryError`, because the tool may have run. The handshake
is never cancelled: a server that does not answer `initialize` is ended.

A stdio server that has stopped for good is not ended by a timeout. Every later
call waits for the timeout again until the host calls `client.close`. The call
after that starts a new server.

A call is also written under `read_timeout`. When a stdio server has stopped
reading its input, a call with large arguments ends there. Half a message is
then left in that server's input, so the server is ended, and the next call
starts a new one with a new handshake.

A server that keeps sending messages and never answers the call starts the
wait again each time, so a bridged tool also has a limit for the whole call:

```ruby
Mistri::MCP.tools(client)                # 300 seconds, Mistri::MCP::CALL_TIMEOUT
Mistri::MCP.tools(client, timeout: 900)  # the host's number
Mistri::MCP.tools(client, timeout: nil)  # no limit
```

`Mistri::MCP.bridge` takes the same option. The limit is the tool's own
`timeout`, so the tool executor ends the call. The model reads that the tool
timed out and may have completed, and the agent goes on. The client sends
`notifications/cancelled` for the call, over stdio and over Streamable HTTP.
The server and its session are kept, and the next call works. A call that
waits behind another call to the same server spends its limit waiting.

A direct `Client#call_tool` has no such limit. A host that puts its own
`Timeout` around one gets the same cancel and keeps the server.

### Ambiguous tool delivery

A response boundary or wire failure after `tools/call` is different from an
ordinary read failure: the server may have received and committed the operation
before the response disappeared.

When no matching result was confirmed, Mistri raises
`Mistri::AmbiguousDeliveryError` and never replays the call automatically. The
message tells the caller to verify external state before any retry.

That is the direct Client contract. A tool bridged through `Mistri::MCP.tools`
runs inside the normal tool executor, which converts the raised exception into
an error-marked tool result for the model and host. The transport still does not
replay the call. A model may choose to issue a new call after reading the error,
so approval, idempotency, and reconciliation remain host policy.

If a matching result arrived before an invalid trailing SSE record, that result
remains authoritative. The connection is closed and the session is kept.

Session-expired and authentication retries occur only through explicit server
responses that establish the request was not accepted under the old session or
credential. An ambiguous outcome never takes those replay paths.

The opposite case is a call that was never sent. A client connects on its
first request, so a server that cannot be reached fails in the handshake,
before `tools/call` leaves. `Client#call_tool` raises a copy of that error
tagged with `Mistri::MCP::NotSent`, of the same class. A bridged tool turns it
into an error result that states no connection could be established and the
tool did not run, so the model does not report a partial effect.

## Remote network policy

Remote MCP and server-side OAuth URLs are untrusted input. By default Mistri:

- requires public HTTPS;
- resolves and validates every DNS answer against special-purpose address
  ranges, including embedded NAT64 destinations;
- rejects the whole result if any answer is unsafe;
- pins an approved address while preserving the hostname for Host, SNI, and
  certificate verification;
- resolves and validates again for each new connection cycle, including an
  internal keep-alive reconnect;
- tries alternate approved addresses only before request bytes are sent;
- follows no redirects;
- ignores ambient HTTP proxy settings.

Private HTTPS servers require one narrow host callback:

```ruby
require "ipaddr"

private_range = IPAddr.new("10.20.0.0/16")
allow_internal = lambda do |uri, address|
  %w[mcp.internal.example auth.internal.example].include?(uri.hostname) &&
    private_range.include?(address)
end

client = Mistri::MCP::Client.new(
  url: "https://mcp.internal.example/mcp",
  allow_non_public: allow_internal,
)
```

The callback is consulted only for otherwise blocked addresses. Match both the
expected hostname and an explicit IP range. It cannot permit an invalid URL.
Plain HTTP remains limited to an explicitly approved address that actually
resolves to loopback, which is suitable only for local development:

```ruby
allow_loopback = ->(_uri, address) { address.loopback? }
```

Pass the same policy to the Client and every OAuth operation for an internal
deployment.

## OAuth

`Mistri::MCP::OAuth` implements the storage-agnostic OAuth 2.1 flow required by
MCP. The host owns the connection record, callback route, token encryption, and
authorization-server selection.

Start discovery and registration:

```ruby
flow = Mistri::MCP::OAuth.start(
  url: server_url,
  client_name: "YourApp",
  redirect_uri: callback_url,
  scope: requested_scope,
  allow_non_public: allow_internal,
)

# Persist the returned flow, then send the user's browser to this URL.
authorize_url = flow.fetch("authorize_url")
```

Persist at least the state, code verifier, client ID and secret, token auth
method, issuer, resource, and redirect URI. `token_endpoint` is returned for
compatibility and display only; later operations rediscover it from the exact
issuer.

The host must compare callback state with the persisted value before exchange:

```ruby
unless host_secure_compare(callback_state, flow.fetch("state"))
  raise "invalid OAuth state"
end

tokens = Mistri::MCP::OAuth.complete(
  code: params.fetch(:code),
  iss: params[:iss],
  code_verifier: flow.fetch("code_verifier"),
  client_id: flow.fetch("client_id"),
  client_secret: flow["client_secret"],
  token_auth_method: flow.fetch("token_auth_method"),
  issuer: flow.fetch("issuer"),
  resource: flow.fetch("resource"),
  redirect_uri: flow.fetch("redirect_uri"),
  allow_non_public: allow_internal,
)
```

`iss:` is the `iss` parameter of the callback, or nil when the callback had
none. Mistri refuses a callback that names another issuer than the one the
sign-in was started with, and one that names none when the authorization
server's metadata says it sends one. It compares the two as they are written,
and it does so before the code is sent anywhere. This is the defence against
an authorization server that tries to collect a code meant for another
(RFC 9207). A host that leaves `iss:` out gets no such check, because Mistri
cannot see the callback.

A callback may carry `error` in place of a code. Check its issuer the same
way before the error is shown to anyone:

```ruby
oauth = Mistri::MCP::OAuth
oauth.verify_response_issuer(params[:iss], oauth.bound_metadata(flow.fetch("issuer")))
```

Refresh tokens can rotate, so persist a returned replacement:

```ruby
tokens = Mistri::MCP::OAuth.refresh(
  refresh_token: connection.refresh_token,
  client_id: connection.client_id,
  client_secret: connection.client_secret,
  token_auth_method: connection.token_auth_method,
  issuer: connection.issuer,
  resource: connection.url,
  allow_non_public: allow_internal,
)
```

An authorization server may omit `refresh_token` or `scope` from a successful
refresh. Low-level callers must retain the current stored value unless the
response supplies a replacement. The generated Active Record adapter already
does this.

Mistri requires S256 PKCE. It follows protected-resource and authorization-server
discovery, binds metadata to exact resource and issuer identifiers, and honors
challenge scope. It does not add `offline_access` as gem policy. A host that
wants a refresh token passes `offline_access: true` to `start`: the scope is
then added when the authorization server lists it, and only to a scope that
is being asked for.

When discovery advertises multiple authorization servers, the host must pass
`issuer:` explicitly. A pre-registered `client_id` always requires the exact
issuer trusted when it was provisioned. Servers without dynamic registration
also accept `client_secret:` and an explicit supported `token_auth_method:`.

OAuth response bodies are uncompressed and bounded to 256 KiB. Provider error
descriptions are not copied into credential-bearing exceptions.

### How the application names itself

There are three ways, and `start` takes them in this order:

1. **A client set up by hand.** Pass `client_id:`, with `client_secret:` and
   `token_auth_method:` when the server gave them, and the `issuer:` it was
   set up at.
2. **A client ID metadata document.** Pass `client_metadata_url:`, the https
   address where the application serves the document. A server whose metadata
   says `client_id_metadata_document_supported` gets that address as the
   client ID, and nothing is registered. The 2026-07-28 revision prefers this
   way.
3. **Dynamic registration**, when neither applies and the server offers it.
   Mistri says what kind of application it registers: `native` for a loopback
   redirect URI and `web` for any other.

The document is the same for every server, so one route serves it:

```ruby
render json: Mistri::MCP::OAuth.client_metadata(
  url: client_metadata_url,
  client_name: "YourApp",
  redirect_uris: [callback_url],
)
```

A client is bound to the issuer that gave it. Store the `issuer` beside the
client ID, and pass both again when the same client signs in later. When the
server no longer names that issuer, `start` raises
`Mistri::MCP::OAuth::IssuerChanged` and registers nothing. A host then drops a
client that was registered dynamically and calls `start` without it, and shows
the error for one that was set up by hand. Mistri does not register with a
new authorization server by itself, because whether to trust it is the host's
decision. A document's address is the same client at every issuer.

### A refused token request

`complete` and `refresh` raise `Mistri::MCP::OAuth::TokenError` when the token
endpoint refuses. `error.reason` is the code it gave, when that is one of the
standard ones, and `error.status` its HTTP status.
`Mistri::MCP::OAuth::InvalidGrantError` is the one a host acts on: the grant
is spent or revoked, so the person signs in again.

```ruby
begin
  tokens = Mistri::MCP::OAuth.refresh(**stored)
rescue Mistri::MCP::OAuth::InvalidGrantError
  connection.update!(status: "needs_sign_in")
end
```

`Mistri::MCP::OAuth.revoke(token:, **stored)` ends a token at the
authorization server. It returns false for a server that names no revocation
endpoint.

### More scope

A server may answer a call with a 403 and a challenge that asks for more
scope. The `Mistri::AuthenticationError` carries the challenge:

```ruby
rescue Mistri::AuthenticationError => e
  asked = Mistri::MCP::OAuth.challenge(e)
  if asked["error"] == "insufficient_scope"
    scope = Mistri::MCP::OAuth.step_up_scope(connection.scope, asked["scope"])
    flow = Mistri::MCP::OAuth.start(url: server_url, scope: scope, **client)
  end
end
```

`step_up_scope` joins what was granted with what is asked, so the new token
keeps what the old one could do. What was granted is `tokens["scope"]`, or
`flow["scope"]` when the token response names none. Stop after a few rounds:
a server that keeps asking is not going to be satisfied.

### Reading how a server signs in

```ruby
found = Mistri::MCP::OAuth.discover(url: server_url)
found["issuer"]                                  # the authorization server
found["scope"]                                   # what a sign-in would ask for
found["server_metadata"]["registration_endpoint"] # absent: set a client up by hand
```

`discover` takes the steps `start` takes and stops before it registers
anything. It returns the resource, the issuer, the scope, and the two
metadata documents as the servers publish them.

### Tolerant discovery

Exact discovery refuses some servers that the official SDKs connect to.
`tolerant: true`, on `discover`, `start`, `complete`, `refresh` and `revoke`,
accepts three things:

- A resource document for the server's origin, or for a path above the
  server's. That resource is then the one tokens are asked for.
- An issuer that differs from the one named by one trailing slash.
- No resource document at all, which is the 2025-03-26 revision: the server's
  origin is the authorization server, and when it publishes no metadata
  either, the endpoints are `/authorize`, `/token` and `/register`.

The third applies only when the documents are not published. A server that
could not be reached, or that answered 429 or a 5xx, ends the sign-in with its
error. None of the three lets a token be asked for another origin. A host
that starts a sign-in tolerantly passes `tolerant: true` to every later step
of it.

## Optional Rails connection generator

Rails applications can generate an encrypted connection model and migration:

```console
$ bin/rails generate mistri:mcp McpConnection
```

Each row stores one server, OAuth flow state, issuer, encrypted tokens, expiry,
and scope. The generated model exposes `connect`, `complete`, token refresh, a
Client, and bridged tools. Set up Active Record encryption before storing
credentials.

The callback passes its `iss` on: `McpConnection.complete(state: params[:state],
code: params[:code], iss: params[:iss])`.

A server retires a refresh token when it is used, so two processes that
refresh one row at the same moment would lose the sign-in. The generated
`bearer_token` locks the row for the refresh and looks again once it holds the
lock. The lock is held while the token endpoint answers.

Override the generated class policy when the server is internal:

```ruby
class McpConnection < ApplicationRecord
  def self.mcp_allow_non_public
    ALLOW_INTERNAL_MCP
  end
end
```

The generator is an adapter, not a requirement. The same OAuth services work in
Sinatra, Hanami, GraphQL, jobs, or any host with a durable record and callback
route.

Generated application files are copies and do not change when the gem updates.
Read the [upgrade guide](../UPGRADING.md) before upgrading an existing generated
connection model.

## Related guides

- [Tool contracts](tool-contracts.md)
- [Sessions and control](sessions.md)
- [Reliability](reliability.md)
- [Upgrading](../UPGRADING.md)
