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

Use `headers:` for fixed application headers. Mistri copies them at client
construction and rejects framing plus MCP session and protocol headers. A fixed
Authorization header is permitted; when `token:` is supplied, Mistri owns
Bearer authorization and overwrites it.

One Client serializes its requests. Parallel Agent tool calls against the same
client queue rather than interleave. Use distinct clients only when the server
and host policy allow true parallel connections.

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

Call `client.close` when a long-lived host is finished. For stdio, it terminates
the child. For HTTP, it closes the local connection and forgets the negotiated
session, but does not send the optional MCP DELETE termination request; remote
resources expire by server policy. The discovered tool cache remains available.
`call_tool` or `tools(refresh: true)` performs a fresh handshake when needed.

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
agent is built. `client.listing` returns the server's tools, and its
`instructions` when it sent any, as plain JSON. Store it, and pass it to the
clients built later:

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

The instructions are text from the server. On every provider they are sent as
text of a user turn, in a system-reminder block that names the tools, and not
inside a tool result. Give them the trust you give that server.

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

`deferred: true` keeps a server's tools out of the model's sight until a search
loads them, so the definitions of a server with a long tool list are left out
of every request until one of its tools is needed. See
[Tools on demand](tool-contracts.md#tools-on-demand).

## Many servers

An agent can be given the tools of tens or hundreds of servers. Four things
keep that cheap, and each is a host decision that Mistri supports:

1. List each server once, in a job, and store the listing. Listing takes a
   connection for each server, so run the servers in parallel and let one
   failure leave the others:

   ```ruby
   listings = servers.to_h do |name, url|
     [name, Thread.new { Mistri::MCP::Client.new(url: url).listing }]
   end
   listings.each do |name, thread|
     store.write(name, thread.value)
   rescue StandardError => e
     report(name, e)
   end
   ```

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

Either failure resets the wire and negotiated session. The next operation must
handshake again.

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
remains authoritative. The wire is still reset for the next operation.

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
challenge scope. It does not add `offline_access` as gem policy.

When discovery advertises multiple authorization servers, the host must pass
`issuer:` explicitly. A pre-registered `client_id` always requires the exact
issuer trusted when it was provisioned. Servers without dynamic registration
also accept `client_secret:` and an explicit supported `token_auth_method:`.

OAuth response bodies are uncompressed and bounded to 256 KiB. Provider error
descriptions are not copied into credential-bearing exceptions.

## Optional Rails connection generator

Rails applications can generate an encrypted connection model and migration:

```console
$ bin/rails generate mistri:mcp McpConnection
```

Each row stores one server, OAuth flow state, issuer, encrypted tokens, expiry,
and scope. The generated model exposes `connect`, `complete`, token refresh, a
Client, and bridged tools. Set up Active Record encryption before storing
credentials.

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
