# Upgrading Mistri

Mistri follows SemVer from 0.x: patches fix behavior, while a minor release may
add features and intentional contract changes. Every change belongs in the
[changelog](CHANGELOG.md); this guide extracts only the work an existing host
may need to perform.

Upgrade a representative application and persisted session set in staging
before production. Do not treat a passing bundle update as a session migration
test.

## Unreleased

Most hosts need no code change. Read the points that apply to you.

### On Claude, Anthropic writes the summary of a compaction

On Anthropic's own origin, for a model its page lists, a compaction now asks
the API for the summary. Mistri sends its own cut and its own summary prompt.

- Most hosts do nothing. The kept turns keep their thinking, and the request
  reads the session's prompt cache.
- The request sends the beta header `compact-2026-09-04`, and so does every
  later request of that session. A gateway that filters beta headers has to
  let it through, or the host sets `Compaction.new(native: false)`.
- A host that shows the summary reads it as before, from `event.content` or
  the entry's `"summary"`. It cannot be edited: the API refuses a changed
  block. The entry also holds `"block"` and `"provider"`.
- The first message of a compacted conversation is then an assistant message
  with one `Content::Compaction` block, where it was a user message with the
  summary. A host that reads `session.messages.first.text` reads nil there.
- A session whose latest compaction Anthropic wrote does not run on another
  provider. Such a run ends with an error that says so.
- For the summary Mistri writes itself, set `Compaction.new(native: false)`.

### A request that is too long has its own error type, and is recovered once

A provider's refusal of an input longer than the model's context window was an
errored message of the type `ProviderError` on Anthropic and Gemini and
`InvalidRequestError` on OpenAI. It is now `ContextTooLongError` on all
three.

- A host that reads `message.error["type"]` to recognise this refusal reads
  the new type. `Mistri::ErrorData.too_long?(message.error)` asks the same.
- An agent with compaction no longer ends the run on this refusal. It compacts
  once and sends the turn again. A host that counted on the error to start
  its own recovery sets `compaction: false` or removes that recovery.
- `event.reason` of `:compacting`, `:compaction` and `:compaction_failed`,
  and the entry's `"trigger"`, can now be `:overflow`.

### On GPT, OpenAI writes the compaction, and nobody can read it

On OpenAI's own origin a compaction now ends its request with a trigger, and
the API returns one sealed item in place of a summary.

- A host that shows the summary has nothing to show for these compactions:
  `event.content`, the entry's `"summary"` and `result[:summary]` are nil.
  `event.status` is `:native`. For a summary a person can read, set
  `Compaction.new(native: false)`.
- `Compaction.new(instructions:)` and `agent.compact(instructions:)` do not
  reach OpenAI's own compaction. They apply to the summary Mistri writes.
- A session whose latest compaction OpenAI wrote does not run on another
  provider, and a fallback of another provider cannot fold that item into a
  later summary.
- With `native: false`, a new compaction on OpenAI puts Mistri's summary
  after the kept turns. A host that reads `session.messages.first` as the
  summary reads the first kept turn there. Sessions compacted before this
  release replay as they did.

### An agent's summary request repeats the conversation

The request that writes a compaction's summary now holds the agent's system
prompt, its tools and the messages up to the cut, and ends with the summary
prompt, as a system message where the provider takes one. Before, it held one
text and the compactor's own system prompt.

- Most hosts do nothing. The request reads the session's prompt cache and
  costs less.
- The request runs with the thinking or reasoning setting of the agent's
  provider. A host that set a large thinking budget pays for thinking in the
  summary too. `Compaction.new(max_tokens:)` still bounds its output.
- A custom provider, a gateway or a test that looked for the text
  `<conversation>` in the summary request finds the conversation's own
  messages, and the summary prompt in the last one.
- A reply that calls a tool is not a summary. The same provider is then asked
  once more, with the text. After any other failure a configured `fallback:`
  is asked with the text, as before.

### A compaction keeps what `keep_recent:` says, and the level reads higher

The context level and the turns a compaction keeps are now measured from the
provider's own counts.

- A compaction with the default `keep_recent:` of 20,000 keeps about 20,000
  tokens. Before, it kept up to 52,960. A host that wants the larger tail
  raises `keep_recent:`.
- The level of a session that no provider has answered, and of a session right
  after a compaction, reads higher than before, because it is closer to the
  provider's count. A host that compares `context_usage[:tokens]` with a
  number of its own checks that number.
- `agent.context_usage` returns three more keys, `estimated`, `threshold` and
  `remaining`. A host that matches the whole hash adds them.
- `Event` has two more members, `tokens_before` and `tokens_after`, and
  `ToolContext` has one more, `compaction`. A host that builds either with
  positional values, or matches one with a pattern of every member, adds
  them. Keywords are unaffected.
- Near the threshold a turn can begin with one request to the provider's count
  endpoint. It is free. It takes about 0.1 to 0.5 seconds on Anthropic and
  Google, and about 13 ms for each 1,000 tokens on OpenAI.

### The cost of some models changed with the vendors' prices

- `gpt-5.6-terra` and `gpt-5.6-luna` cost less, as OpenAI now bills them.
  `gpt-5.6-sol` is on OpenAI's promotional price until the end of
  November 30, 2026, Pacific time.
- `gemini-3.5-flash` is priced as `gemini-3.6-flash`, which is the model that
  answers it.
- A host with a cost budget on one of these models reaches it later.

### Gemini 4 compacts earlier than Gemini 3

Input, thinking and output share the window of a Gemini 4 model. Automatic
compaction starts at 978,944 tokens on these models. A host that moves a
session from a Gemini 3 model to a Gemini 4 model does nothing, and sees the
first compaction earlier.

### OpenAI receives the system prompt as a developer message

On OpenAI's own origin the system prompt is now the first item of `input`, a
message with the role `developer`. The request holds no `instructions`.

- Most hosts do nothing. On GPT-6.2 the system prompt is read from the cache
  from the second request on. On earlier models the cost does not change.
- A gateway or a test that reads `instructions` from the request body reads
  the first input item.
- A session on GPT-6.2 that began on an earlier release loses the reasoning of
  its earlier turns once, on its first request after the upgrade. The stream
  says so with `:thinking_dropped`.
- Another origin still receives `instructions`. Through a gateway GPT-6.2
  therefore does not cache the system prompt.

### A usage dumped with Marshal is not read by an earlier release

`Mistri::Usage` now dumps itself in its own form, so that it can carry the
context of a turn that took several requests. This release reads a dump of an
earlier one. An earlier release raises `TypeError` on a dump of this one, and
a `Mistri::Message` holds its usage.

- A host that stores sessions through a store does nothing. Stores write JSON.
- A host that keeps a message, a usage or a run result in a Marshal cache
  clears that cache before it rolls back, and does not run two releases on one
  cache.

### A bridged MCP tool has a limit of 300 seconds

A tool from `Mistri::MCP.tools` or `Mistri::MCP.bridge` now ends as a tool
error when one call takes more than 300 seconds in all.

- For a server whose calls rightly take longer, pass the seconds:
  `Mistri::MCP.tools(client, timeout: 1800)`.
- For the earlier behaviour, pass `timeout: nil`.

### A key of `gates:` that names no tool raises

`Mistri::MCP.tools(client, gates: { "create_issue" => true })` now raises
`Mistri::ConfigurationError` for a key that names no tool the server lists.
Before, such a key was ignored and the tool ran with no approval.

- Keys are remote names, as strings. A symbol names no tool.
- A host that passes one hash to several servers gives each server the keys
  of its own tools:
  `gates: GATED.slice(*client.tools.map { |tool| tool["name"] })`.
- A server that drops or renames a gated tool makes `MCP.tools` raise until
  the hash is changed.

### `Mistri::MCP.tools` returns a tool that reads resources

For a server that declares resources, `Mistri::MCP.tools` now returns one
more tool than the server lists: `read_resource`, under the server's prefix.

- A host that wants the list as it was passes `resources: false`.
- A host that passes `allow:` gets the tool only when the list names
  `read_resource`, and `deny:` leaves it out by the same name.
- A host that gates a server's tools gates this one with
  `gates: { "read_resource" => true }`, or with `needs_approval: true`.
- A listing stored before this release has no `"resources"` key, so a client
  built from it offers no such tool until the server is listed again.
- A result that held bytes used to show the line `[resource: uri]`. It now
  shows an image, or the text, or where the bytes were saved.

### MCP sign-in checks more, when the host hands it more

- Pass the callback's `iss` to `OAuth.complete`: `iss: params[:iss]`. Without
  it nothing changes, and a callback from another authorization server is not
  told apart.
- A host that matched the text `invalid_grant` in an error message rescues
  `Mistri::MCP::OAuth::InvalidGrantError` instead. The message is unchanged.
- A host that stores a client it registered and passes it to `OAuth.start`
  with its `issuer:` rescues `Mistri::MCP::OAuth::IssuerChanged`, drops that
  client and starts again without it. Before, the same case raised
  `Mistri::MCP::Error` with the same message.
- After a 403 whose challenge says `insufficient_scope`, the MCP client raises
  at once. Before, it asked the token callable once more and sent the request
  again. Read the challenge with `OAuth.challenge(error)`.
- An application generated the connection model from an earlier release keeps
  its copy. To get the lock around the refresh, copy `bearer_token` and
  `stale?` from the new template, and pass `iss:` from the callback.
- `OAuth.start` returns one more key, `"scope"`.

### A bridged MCP tool says which server could not be used

- The text of a bridged tool's result changed for a server that cannot be
  used. It names the server by its `prefix:`, and says so when the server
  needs a sign-in. A host that matched the text
  `No connection to the MCP server could be established` matches
  `did not run` instead.
- `Client#call_tool` raises a `Mistri::ProviderError` tagged
  `Mistri::MCP::NotSent` when no connection could be opened. Before, it raised
  `Mistri::AmbiguousDeliveryError`, which says the call may have completed.

### A bridged MCP tool's description is cut at 4,096 characters

A longer description now reaches the model cut, with a line that says so.
Pass `description_limit: nil` to `Mistri::MCP.tools` for the earlier
behaviour, or another number.

### The MCP client asks a server which revision it speaks

The client now sends `server/discover` before its first request, and uses the
2026-07-28 form with a server that offers it.

- A server that speaks only an older revision gets one request more when a
  client first connects. Store `client.listing` and build clients from it:
  such a client asks nothing.
- `client.listing` has a new key, `"protocolVersion"`. A listing stored
  before this release still works, and its client asks once.
- A server that offers 2026-07-28 gets no `initialize` and no session. A host
  that reads `client.server_info` on a client built from a stored listing
  gets nil, because nothing was asked.
- Over HTTP in the 2026-07-28 form, a direct `Client#call_tool` on a client
  that holds no listing lists the tools first.
- `Mistri::MCP::Client::PROTOCOL_VERSION` is `"2026-07-28"`. The revision the
  handshake offers is still 2025-11-25.

### MCP over HTTP keeps a session and ends it

- `Client#close` now sends a DELETE with the session id. A server that counts
  on sessions being left open sees them end.
- After a failed call the next call uses the same session. Before, the client
  did the handshake again.
- A timeout of a list raises `Mistri::MCP::Error`. Before, it raised
  `Mistri::ProviderError`. Both are a `Mistri::Error`.
- The message of an HTTP error from an MCP server changed. A host that matched
  the text `provider request failed` matches the class or `status` instead.
- `headers:` no longer takes `Last-Event-ID`, `Mcp-Method` or `Mcp-Name`.
- `read_timeout` is now the wait for one message. A call that takes longer
  than `read_timeout`, 120 seconds unless the host set another, on a server
  that sends only comments to keep its stream open, now ends at
  `read_timeout` with `Mistri::AmbiguousDeliveryError`. Before, each comment
  started the wait again and the call returned its answer. Pass a longer
  `read_timeout`, or `progress: true` for a server that reports progress,
  because a progress notice is a message.

### A timeout no longer ends a stdio MCP server

When `read_timeout` passes, the client cancels that one request and keeps the
server. Before, the server was ended and the next call started a new one.

- After a request with no answer, the client asks the server for a sign of
  life before the next request. A server that gives none is ended, and the
  request starts a new one.
- A server that answers that question and still never answers a call is kept.
  A host that relied on a new server after every timeout calls
  `client.close` itself. The next call then starts one.
- A line on a stdio server's stdout that is not JSON no longer fails the call.
  It is written to standard error with the prefix `mistri:`.
- `client.close` takes up to half a second longer for a stdio server that does
  not end when its input closes.

### The calls of a turn run in the order written

A tool used to run at the same time as the other calls of its turn. It now
runs alone, in its place, unless it is marked.

- Mark each tool of yours that only reads:
  `Mistri::Tool.define(name, description, parallel: true)`. Until then a turn
  of several of them runs one call at a time, and one that fails holds back
  the calls after it.
- A call written after a call that is not marked and failed, was refused or
  was blocked is no longer run. It answers `Not run: ...`, and the model sends
  it again.
- A call written after a call that waits for approval is no longer run before
  the decision, whether it is marked or not. It answers `Not run: ...`, and
  the model sends it again once the person has decided. One that needs
  approval itself waits with it, unless a call that is not marked and does not
  wait comes between them. Before, every such call ran at once. For a
  Gemini turn whose calls carry no IDs, a call that needs approval does not
  wait when a later call of the same name is answered before it: it answers
  with an error, and the model sends the calls again.
- `MCP.tools` marks a tool that its server lists with `readOnlyHint: true`.
  Pass `parallel: false` for a server whose hints you do not trust, or a hash
  by remote name for single tools, such as a tool that only waits.
- A call that runs by itself now runs on the thread that called the agent,
  not on a thread of its own. What its handler sets on the thread stays set
  after the run, and a `throw` to a `catch` around the run now ends the run.
  Inside a Rails job or request it sees the `Current` attributes set there,
  it uses that thread's database connection and any transaction open on it,
  and an error it raises is no longer reported to `Rails.error` on its way to
  becoming a tool result.
- A host that set `max_concurrency: 1` to get order can drop it.

### A tool's image reaches GPT and Gemini models

A tool result that holds an image used to reach an OpenAI or Gemini model as
its text and the line `[1 non-text block(s) omitted]`. The image is now sent.

- Every request that carries the result costs the image's tokens. A session
  with many screenshots costs more on these providers than it did.
- Another origin of the OpenAI provider receives the image the same way, as
  an array in the output of the function call, and must take one.

### An image Anthropic or OpenAI would refuse is sent as text

Anthropic and OpenAI take PNG, JPEG, GIF and WebP. An image of another format
in a tool result or a user turn ended the request, and every request of the
session after it. Both providers are now sent an image by its first bytes: one
of the four formats with the type its bytes show, and any other image as a
line of text that says an image was not sent and why.

- A host that drops such an image in `after_tool` or `transform_context:`
  only to keep the session going can stop. A host that converts one should
  keep doing so: the model sees the converted picture, and only a line of text
  without it.
- A session that such an image ended works again from its next request.
  Nothing stored changes.
- A model on these two providers no longer receives an image whose bytes are
  not one of the four formats, whatever its label says. That holds for every
  origin of the two providers.
- An image whose label is not the type its bytes show, such as `image/jpg` or
  a JPEG labelled `image/png`, is sent with its real type. Anthropic refused
  both. An MCP server that names no type for a JPEG produced the second.
  OpenAI took both, so a stored request that holds one differs once from the
  request sent before and can miss the prompt cache once.
- A session that moves to one of these two providers from a provider that
  took the image goes on, where it was refused. The model there is not sent
  the image, and when asked about it can say that an earlier answer about it
  was a guess.
- An image over a provider's size limits is still refused, and so is one whose
  data is broken. The refusal still ends the session. Make a large image
  smaller in `after_tool`.

### An image holds strict base64

`Content::Image` kept the base64 text it was given. Every provider refuses
base64 with line breaks, which is what `Base64.encode64` writes, and
Anthropic and OpenAI also refuse base64 without padding or in the URL-safe
alphabet. One such image ended the session. An image now holds strict base64,
whatever form it was built from.

- Nothing to change. `Content::Image.new(data: Base64.encode64(bytes), ...)`
  now works.
- `image.data` is the strict form, so it can differ from the text the image
  was built from. `image.bytes` used to raise for those forms and now works.
- A session that such an image ended works again when it is read. The stored
  entry is not rewritten.
- An image from an MCP server whose data is in the URL-safe alphabet used to
  be damaged on its way in. It is now read as the server meant it.
- Building an image checks its data, at about 0.4 ms for each megabyte. A
  session builds its messages again from the stored entries for each request,
  so a request costs about 1 ms more for each megabyte of images the session
  holds. An image stored in another form is written again each time, at about
  4 ms for each megabyte.

### Gemini 2.5 models are removed

Google retired `gemini-2.5-pro` and `gemini-2.5-flash`. The catalog no longer
lists them.

- Name a current model, for example `gemini-3.8-flash`.
- An agent with a cost budget on a 2.5 model now raises
  `Mistri::ConfigurationError` when you build it.

### Provider defaults changed

A provider built without `model:` now uses `claude-opus-5-5`, `gpt-6.1-sol`, or
`gemini-3.8-flash`.

- Pass `model:` to keep an earlier model.

### Stdio MCP servers no longer inherit the host environment

A stdio MCP server used to get every variable the host process had, provider
keys included. It now gets `env:` and a fixed list: identity and `PATH`,
RubyGems paths, locale and temp files, and CA bundle paths. `docs/mcp.md` names
each variable.

- Pass a variable the server relied on through `env:`. For example,
  `env: ENV.slice("HTTPS_PROXY", "NO_PROXY")` forwards the proxy settings.
- A Ruby server no longer runs inside the host's bundle. Start it with
  `bundle exec` if it needs the host's gems, and pass Bundler settings the
  host keeps in its environment, such as `BUNDLE_PATH`, through `env:`.
- `env: ENV.to_h` passes the whole environment, as before.

### A bridged MCP tool may get another name

`MCP.tools` and `MCP.bridge` now give a tool a name every provider takes:
letters, digits, underscores and hyphens, 64 characters at most, not starting
with a digit or a hyphen. The whole name decides: the prefix, two underscores
and the remote name, or the remote name alone. One inside that set is
unchanged.

- Any other changes, even where your one provider took it: a dot or a colon
  on Gemini, a leading digit or more than 64 characters on Anthropic. The new
  name ends in a short hash of the whole name.
- The remote name alone does not tell you. `9lives` under the prefix
  `tracker` stays `tracker__9lives`, and `read` under a prefix with a dot, or
  a long one, changes.
- `Mistri::MCP.local_name(remote, prefix)` gives the new name, for a host that
  stored the old one.
- To keep a name of your own, bridge that tool with
  `MCP.bridge(client, definition, name: "yours")`. That name is used as
  given, so it has to be one your provider takes.
- `allow:`, `deny:` and `gates:` still go by the remote name.

### A session can hold a system message

An agent appends a system message with `reminder` set to the session when it
holds a deferred tool, and when a tool was bridged from an MCP server that
sends instructions. Mistri wrote it for the model. It is not the user's
message.

- Allow the `system` role where code reads `Session#messages` by role. In a
  view that shows a conversation to a person, leave out a message whose
  `reminder` is set.
- Keep these messages in a `transform_context` lambda. One that drops them
  takes the list of deferred tools and the servers' instructions away from the
  model.
- A provider class of your own needs no change. It is given each one as a user
  message whose text is in a system-reminder block.

### An MCP server's instructions reach the model

A server may send `instructions` in its initialize result. `MCP.tools` now
sets that text on every tool it bridges, and an agent appends it to the
conversation, cut at 2,000 bytes for each server. It is appended with the
agent's first request. When the instructions of all servers are more than
20,000 bytes together, those of a server whose tools are all deferred are
appended once one of its tools is loaded. On an earlier release the model
received none of it.

- Read what each server sends with `client.instructions` before you upgrade.
- Pass `instructions: false` to `MCP.tools` to leave a server's instructions
  out, or a string to send your own text in their place.
- A session from before the upgrade gets the message appended on its next run,
  by the same rule.

### Blank input raises

`Agent#run` and `Session#steer` now raise `ArgumentError` for text that is
empty or only whitespace. Before, `run` sent whitespace to the provider, and
`steer` accepted any text.

- Check the text before you call them, or rescue `ArgumentError`. `Child#say`
  raises the same way.
- `run` still accepts images with no text. `task` is unchanged.

### The JSONL store checks session ids

`Mistri::Stores::JSONL` now raises `ArgumentError` for a session id that holds
a character outside `A-Z`, `a-z`, `0-9`, `_`, and `-`, or is longer than 249
characters. Before, it replaced every other character with `-`, so two ids
could share one file.

- To keep an existing session, use its id with each other character replaced
  by `-`. That is the name of its file: `user:42` is stored as `user-42`.
- New session files are created with mode 0600. Existing files keep their
  mode.

### A session reads only what is new

A session reads its log from the store once and then asks only for the entries
appended since. The built-in stores support this. A custom store keeps working
unchanged: without `settled?` it is read whole on every read, as before.

- To let a session read a custom store in part, add `load(id, from: 0)` and
  `settled?` as [Sessions and control](docs/sessions.md#reading-only-what-is-new)
  describes.
- A subclass of a built-in store, or a wrapper that forwards every method,
  already answers `settled?`. Its own `load` must take `from:`.
- Inside a transaction that Active Record opened, a session reads fresh and
  holds nothing, so what it answers there is unchanged. A transaction begun
  with raw SQL is invisible to the store; do not read a session inside one.
- The Active Record store raises `Mistri::ConfigurationError` when the rows it
  reads are not at consecutive positions. Rows that are only ever appended sit
  at positions 1, 2, 3. Delete a session's rows together, never some of them.
- The Active Record store needs READ COMMITTED or a stronger isolation level
  on the connection that reads. MySQL and PostgreSQL have that by default.
- A `Session` object holds the entries of its window in memory, image data
  included, for as long as the object lives. After a session's rows are
  deleted, build a new `Session` object. A `Child` holds every entry of its
  worker's log the same way.

### A session starts at its newest checkpoint

A compaction now carries what a turn needs from before it, and a session
reads, replays and audits from the newest one on, however long its log is. A
compaction written before this release carries nothing, so such a session is
read whole until its next compaction.

- A tool call id must be unique within the session's window, the entries from
  the newest checkpoint's `kept_from` on. It used to be unique over the whole
  session.
- `approve` and `deny` repeated for a call that was settled before the newest
  checkpoint raise `Mistri::ConfigurationError` ("no open approval"). They
  used to return nil.
- An entry older than the window is no longer replayed or audited as a
  message. A store may still decode it while the window is being found.
- To let a session find its window in a custom store without loading the
  rest, add `size(id)` and take `to:` in `load`, as
  [Sessions and control](docs/sessions.md#starting-at-the-newest-checkpoint)
  describes. Without them the store is read whole, as before.
- A subclass of the memory or Active Record store, or a wrapper that forwards
  every method, already answers `size`. Its own `load` must take `to:` as
  well as `from:`.
- An `approval_decision` entry now records `request`, the position of the
  approval request it answers, and applies only to that request. Decisions
  written earlier have no `request` and keep working as before.
- Code that appends a compaction entry itself should call
  `Session#checkpoint(summary:, kept_from:)`, so the entry carries what is
  needed from before it. The start must be a user message, an assistant turn
  that calls tools, or the end of the log. It raises
  `Mistri::ConfigurationError` for any other start, and for one that would
  move back or pass an open approval or a steer or report not folded in yet.
  A compaction appended with `Session#append` still replays correctly, and
  the session is read whole while it is the newest one.

### A session's string id is fixed

`Session.new` keeps its own copy of a string id, and `Session#id` returns a
copy. Changing either string in place no longer changes which session is read
and written. Build a new `Session` to work with another id. An id that is not
a string is kept as the object it was given. A `Child` treats its `session_id`
the same way.

### The generated session table has one index

The install generator no longer adds an index on `session_id` alone. The
unique index on `[session_id, position]` serves every query the store sends,
and a read or a delete of a whole session.

An existing table keeps working as it is. Removing the extra index is
optional:

```ruby
remove_index :agent_entries, :session_id
```

It saves the storage of that index: about half of the table's secondary index
size on MySQL 8.4 and a fifth on PostgreSQL 14, measured on 220,000 rows. The
measured time of an append was unchanged. Keep the index if your own queries
on the table use it.

### The single-value workspace recipe borrows its connection

The recipe for `Mistri::Workspace::Single` asked
`page.class.connection.transaction_open?`. On Rails 7.2 and later, asking a
model for its connection keeps that connection checked out until the job ends.
If you copied the recipe, borrow the connection instead:

```ruby
page.class.connection_pool.with_connection(&:transaction_open?)
```

The Active Record workspace and session store need no change in your code.

### One runner per session is checked

Only when `Mistri.locks` is set:

- A second concurrent `run`, `resume`, `task`, or `compact` raises
  `Mistri::SessionBusyError`. Retry, or report the session busy.
- So does a call back into a running session. From an event subscriber the
  error reaches the host. From a tool it comes back to the model as that
  tool's error and the run goes on.
- After a crash, runs can raise it for up to three minutes. So can runs after
  a failed release.
- When the lock backend is down, a top-level run warns and goes ahead without
  its lease. A sub-agent still fails with a report, as before.
- A session has one lease. Pass `lease: false` to `Agent.new` when your own
  code already holds a lock for the session.
- `Locks::RailsCache` on a null cache store, the Rails default in development
  and test, grants every lease, so two runs can write one session. Mistri now
  warns when it is given one. Give the adapter a real store there too.

### The retry note names the failure

The `:retry` event's `content` and the run log now read "attempt 1 failed
(OverloadedError 529); retrying in 0.9s". Before, they read "attempt 1 failed;
retrying in 0.9s".

- Code that matches the old text follows. `attempt`, `max_attempts` and
  `delay` on the event are unchanged.

### OpenAI tools are no longer strict

Mistri sends `strict: false` with every OpenAI tool. Before, the model wrote a
value into every optional field, for example `""`, `0`, or `[]`.

- Remove code that ignores those made-up values.
- Mistri still validates arguments against your schema before the handler runs.

### A changed prompt costs thinking, not the session

Current Claude models reject earlier thinking when the system prompt or a tool
definition changes. Mistri now asks the API to drop that thinking, and the
request succeeds.

- Keep the system prompt and tool definitions stable during a session. The
  model repeats dropped reasoning, which costs output tokens.
- Handle the new `:thinking_dropped` event to see when this happens. The run
  log prints a warning.
- Mistri sends the control only to `api.anthropic.com`. For another `origin:`,
  set it yourself:

```ruby
Mistri.agent(
  "claude-opus-5-5",
  provider_options: {
    origin: gateway_url,
    thinking: { type: "adaptive", display: "summarized",
                block_binding: { prefix_mismatch_behavior: "drop_block" } },
  },
)
```

### An empty completion after text ends the turn

A model that has written to the user and then called a tool often answers the
tool's result with an empty completion. 0.7.0 sent the same request up to
three more times. The turn now ends there.

- `result.text` of such a run reads the text the model wrote before the tool
  call, which `result.said` holds. It read the empty final message before. A
  host that shows the streamed text and then adds `result.text` reads
  `result.message.text` for the final message alone.
- An empty completion is still retried while the model has written no text
  since the user's last message.

### A gated tool tells the model

The description a provider receives for a tool with `needs_approval` now ends
with "A person reviews each call before it runs." `Tool#description` returns
your text unchanged.

- Remove the same sentence from your own descriptions.

### The document tools changed

`Mistri::Tools.files` returns `read_file`, `write_file`, `edit_file`, `grep`,
`list_files` and `delete_file`.

- `find_in_file` is not among them. A host that names its tools one by one,
  in a definition or a list, names `grep` instead. `Mistri::Tools.find_in_file`
  still builds the old tool for a host that adds it itself.
- `delete_file` is new. Leave it out of the tools you pass when the model
  must not delete.
- An agent refuses two tools of one name when it is built. A tool of your own
  named `grep` or `delete_file`, passed beside `Tools.files`, now raises
  "duplicate tool names: grep". Rename yours, or leave the built-in one out.
- `write_file` no longer replaces a document blindly. To replace one that
  exists the model passes `if_version`, which `read_file`, `write_file` and
  `edit_file` state in their results. A prompt that tells the model to
  overwrite a document should say to read it first, or to edit it.
- The text of the results changed. `read_file` begins with the path, the
  version and the range, `list_files` adds each size, and `edit_file` ends
  with the new version. Code that reads these texts follows.
- A custom workspace needs no change. Add `sizes(prefix = nil)`, a Hash of
  path to bytes, to have `list_files` show sizes.
- `list_files` shows 200 paths at most and says how many it left out. It
  listed every path before.
- `Mistri::Tools.numbered_window` and `Mistri::Tools::MAX_READ_CHARS` are
  gone. `read_file` sizes a part in bytes, by `MAX_READ_BYTES`.

### A large tool result is cut

A result over 50,000 bytes is stored as its start and one line that states its
true size, and the results that answer one assistant message share 200,000
bytes. Before, every result was stored whole, and one larger than the model's
window left the session unusable.

- The rest of a cut result is not kept anywhere. Give a tool that can return
  more than the limit a way to ask for less, such as a page or a filter. The
  line the model reads asks it to call the tool again for the part it needs.
- `after_tool` still receives the whole result. A host that keeps large
  results itself does it there.
- A tool message may hold `cut`, the true bytes and lines. Code that reads
  session messages can show it. No provider is sent it.
- The `:tool_result` event and its message carry the stored text. A host that
  shows or saves tool output from the event gets the cut result. A view of its
  own can travel in `ui`, which is never cut.
- Pass `result_limit: Mistri::ResultLimit.new(bytes:, turn_bytes:)` for other
  numbers. `result_limit: false` stores every result whole, as before.
- A background child takes `result_limit:` on its `Runtime`.

### A path from the model is checked

The document tools refuse a path that is not plain and relative before any
workspace is asked: one that starts with `/`, holds an empty part, `.` or
`..`, a backslash or a control character, or is longer than 512 bytes.

- A document stored under such a path, as `/index.html` could be on the
  memory and Active Record workspaces, is no longer reachable through the
  tools. Rename it.
- The model reads why a path was refused and sends a relative one.

### A scratchpad keeps what a cut would lose

Nothing changes until you pass `scratchpad:` to an agent.

- Pass a workspace scoped to the session. On the Active Record workspace that
  is the same table with the session in the scope.
- If you pass your own document tools, bind them to the same workspace, so
  the path in a stored result is one the model can read. If you pass none,
  the agent adds all six, and they reach every path of that workspace, not
  only `scratchpad/`.
- A path under `scratchpad/` belongs to the agent. `write_file`, `edit_file`
  and `delete_file` refuse `scratchpad/tool-results/`.
- A session with a scratchpad holds a system message with `reminder` set to
  `scratchpad`. Leave it out of a view for a person, as with the others. It
  follows the user's first message, so a test that expects the user's message
  last in the first request reads the last user message instead.
- A result over its limit is stored as its first 2,000 bytes and the path of
  the whole, where an agent with no scratchpad keeps 50,000 bytes.
- Saved results are rows the host owns. Delete them with the session.

### Code the model writes

Nothing changes until you pass `sandbox:` to an agent.

- Add the `wasmtime` gem, require `mistri/sandbox/quickjs`, and keep the file
  `quickjs.wasm` of the npm package `quickjs-wasi` 3.7.0 with your
  application. Build one adapter for the process. On a server that forks its
  workers, build it before the fork and run code only in the workers.
- An event subscriber sees `:tool_started` and `:tool_result` for calls the
  code makes. Their call ids begin with `code_`, and their `message` is not
  among the session's messages. Both events carry the short copy that is
  stored: 2,000 bytes of the call's arguments, and the first 2,000 bytes of
  the result with the true size in the message's `cut`. The whole of both
  went to the tool and to the code.
- A session holds entries of type `code_call`. Code that reads
  `Session#entries` by type leaves them out of a transcript for a person, or
  shows them under the `run_code` call they belong to. An entry keeps 2,000
  bytes of the call's arguments, and the first 2,000 bytes of its result with
  the true size, and not the result's `ui`, which the `:tool_result` event
  carries. One run stores its first 100 calls. The events are emitted for
  every call.
- A session also holds entries of type `code_documents`: the paths and the
  versions of the documents a run of code read or wrote. They let a later run
  write over a document that code read or wrote before. Where you render
  `Session#entries` or `Session#transcript` for a person, skip them, as you
  skip `code_call`.
- `before_tool` is asked about every call from code, by the name of the tool:
  `read_file`, `write_file`, `list_files` and `delete_file` for the four file
  operations, with what the code passed. The code receives what `after_tool`
  returns, and for `files.read` the hook is given the document.
- `files` in code works through the built-in document tools. Where a document
  tool is your own, code calls it as a tool, under its contract and its
  approval rule.
- Code computes inside the host's process and holds Ruby's interpreter lock
  while it does. The lock is passed on in the code's own loops, and not during
  one built-in call such as a search in a long string, so other threads can
  wait for as long as `timeout:`. Keep it short on a process that serves
  requests. `timeout:` bounds the code's own computing and `total_timeout:`
  the whole run with its calls.
- The result of `run_code` keeps 10,000 bytes, and the tool's description
  states it.
- A child takes `sandbox:` as an agent option, on a `Runtime` too. Its code
  reaches only the tools and the documents the child was granted.

### The token estimate after a Claude turn

A tool result that follows a Claude turn is estimated at two characters a
token. It was four. `Session#context_tokens`, `Agent#context_usage` and the
compaction trigger read higher for such a session, so it compacts earlier.
You do not need to change anything.

### Skills

- `read_skill` now marks an unknown skill name as a failed tool result.
- Gemini also receives a loaded skill in its system instruction. You do not
  need to change anything.

## From 0.5.x to 0.6.x

This is a safety-focused minor upgrade. The built-in Anthropic, OpenAI, and
Gemini providers preserve ordinary 0.5 sessions, including the repeated
`call_N` IDs older Gemini and Fake-provider turns generated after the earlier
occurrence settled. There is no blanket session rewrite step.

Hosts that used implicit tool schemas, mutated arguments, supplied custom
providers or Session stores, dispatched background children, used document
workspaces, generated MCP OAuth models, stored sessions in MySQL, or configured
cost budgets need to review the sections below.

### Checklist

- [ ] Declare every argument a model may send to a formerly schema-less tool.
- [ ] Remove handler or policy mutations of model argument hashes and arrays.
- [ ] Replace implicit coercion with an explicit per-tool normalizer where it is
      genuinely part of the contract.
- [ ] Make event subscribers tolerate new event types and read `tool_error`
      structurally.
- [ ] Audit synchronous event subscribers: their exact exceptions now escape
      `run` or `resume` and may follow durable facts or external side effects.
- [ ] Ensure at most one `run` or `resume` is active per Session across all
      processes.
- [ ] Treat each approval as single-assignment; resolve quorum or multi-reviewer
      policy in the host before calling `approve` or `deny`.
- [ ] Verify every successful custom Session-store append is visible to later
      loads in the same stable per-session order.
- [ ] Audit custom provider tool-call IDs, names, arguments, and metadata.
- [ ] Widen Active Record session payloads to LONGTEXT on MySQL or Trilogy.
- [ ] Update generated MCP OAuth models to persist issuer and share egress
      policy across the complete flow.
- [ ] Review the new MCP and provider response limits and ambiguous-delivery
      behavior.
- [ ] Configure a deterministic standard service tier for any cost budget.
- [ ] Remove intentional symlinks from model-controlled Directory workspaces.
- [ ] Add a runtime factory to every background spawner and queue worker.
- [ ] Review queued child specs and ensure their exact `tool_names` grant is
      still intended before executing them under 0.6.
- [ ] Keep qualifying Active Record workspaces outside host transactions and
      assert `atomic_writes?` at boot when lost-update protection is required.
- [ ] Replace mutation of values returned by `Workspace::Memory#read` with an
      explicit `write`.
- [ ] Use anchored `edit_file`, not blind `write_file`, when concurrent changes
      must be preserved.
- [ ] Exercise active persisted sessions, approvals, tool failures, compaction,
      and one real call per configured provider in staging.

## Background children reconstruct their runtime

A dispatcher no longer captures the spawn-time provider, Tool objects, Agent
options, or their workspace closures. Every spawner with `dispatcher:` must now
provide a host-owned `runtime_factory:`. Mistri invokes it inside the worker and
requires a `Mistri::SubAgent::Runtime`:

```ruby
runtime_factory = lambda do |spec|
  workspace = HostWorkspaces.for_child(spec.fetch("session_id"))
  provider = HostModels.build(spec.fetch("model"))
  tools = HostTools.build(spec.fetch("tool_names"), workspace: workspace)

  Mistri::SubAgent::Runtime.new(
    provider: provider,
    system: HostAgents.system_for(spec),
    tools: tools,
    cleanup: -> { HostAgents.release(provider: provider, tools: tools) },
    budget: HostAgents.child_budget,
  )
end

spawn = Mistri::SubAgent.spawner(
  provider: child_provider,
  tools: declared_tools,
  dispatcher: Mistri::Dispatchers::Thread.new,
  runtime_factory: runtime_factory,
)
```

The provider model and unique Tool names returned by the factory must match the
versioned dispatch spec exactly. Mistri rejects missing, additional, duplicate,
renamed, or reconstructed statically approval-gated tools before the provider
runs. This turns `tool_names` into a durable capability grant rather than queue
metadata. A versioned spec and its exact parent routing are also stored in the
child Session; a changed queue copy raises without failing or reporting the
legitimate child.

`cleanup:` is optional and called exactly once after Mistri accepts a Runtime,
including after validation or execution failure. Use it for per-child provider
sockets, MCP subprocesses, and other host-owned resources. It never masks the
primary error. `skills:` is rejected because it would add an
undeclared `read_skill` tool. Spawner Agent options apply only to inline
children; declare background Agent options on the Runtime.

Sub-agent Agent options are now limited to `budget`, `max_concurrency`,
`transform_context`, `compaction`, `retries`, `skills`, `before_tool`,
`after_tool`, and application `context`; background Runtime still rejects
`skills`. Lifecycle keys such as `session`, `task`, `signal`, and `emit` are
owned by the child and cannot be overridden through generic keyword options.

The model-facing `workspace` argument has been removed. It never cloned a Tool
closure or proved isolation. Existing queued specs that contain `workspace`
remain readable, but new specs omit it. Build child-scoped resources from
trusted host state and stable identifiers such as `session_id`; a retry should
reopen the same durable scope. Inline children still use the exact objects the
host supplied and may share their backends.

Queue jobs should pass the factory into the lifecycle entry point:

```ruby
Mistri::SubAgent.run_dispatched(
  spec,
  store: mistri_store,
  runtime_factory: HostAgents.method(:runtime_for),
)
```

Factory exceptions are retryable by default: the child remains non-terminal
and the exception returns to the queue. Pass `retry_factory_errors: false` on a
final attempt to persist and report the failure before the exception re-raises.
The flag does not control the job system's retry or discard decision. The
built-in Thread and Inline runners use terminal behavior because they have no
durable retry owner.

If the queue copy differs from the stored grant, `run_dispatched` raises
`Mistri::DispatchGrantError` without touching the legitimate child. Treat the
unchanged job as poison: discard it and alert rather than retrying it. This
error is reserved for Mistri's stored-grant binding; do not raise it from a
runtime factory.

The compatible direct `provider:`, `system:`, and `tools:` form remains, but it
now receives the same exact model and tool-grant validation. A job that used to
pass its entire registry must instead reconstruct only the Tool objects named
by `spec.fetch("tool_names")`.
Legacy 0.5 specs keep their serialized grant, including any broad grant created
by the old empty-Definition bug. Their old child entries also have no stored
copy against which Mistri can verify capability or report-routing changes.
Drain or review unversioned queued work before relying on the new boundary.

Tool selection now distinguishes omission from an explicit empty list. Omitted
`tools` means the general pool or a typed Definition's defaults. `tools: []`
means no tools for either worker shape, and a typed Definition that declares no
tools no longer inherits the general pool.

## Tool schemas are enforced locally

Model-originated arguments now cross ownership and schema validation before
`before_tool`, approval predicates, `ends_turn`, MCP, or handlers.

Invalid input receives a bounded error result the model can correct. Valid
sibling calls still run. Mistri does not coerce values.

### Schema-less tools are closed

In 0.5, the no-argument wire schema did not explicitly reject extra fields. In
0.6, a tool without `schema:` or `input_schema:` is a closed no-argument tool.

No change is needed when the tool truly accepts no arguments:

```ruby
Mistri::Tool.define("current_time", "Returns the current time.") do
  Time.now.utc.iso8601
end
```

Declare every accepted field when the handler uses arguments:

```ruby
Mistri::Tool.define("lookup", "Looks up one account.", schema: lambda {
  string :account_id, "Account ID", required: true
}) do |args|
  Accounts.fetch(args.fetch("account_id"))
end
```

For an intentionally freeform object, say so explicitly:

```ruby
input_schema = {
  type: "object",
  additionalProperties: true,
}
```

The schema-less wire shape changes once, so provider prompt caches for affected
tool sets will re-warm after deployment.

### Supplied objects remain open by default

JSON Schema object properties do not close the object. If extra keys must fail,
use a raw schema with `additionalProperties: false`. Otherwise extract declared
fields instead of mass-assigning the complete argument hash.

### JSON Schema dialect and subset

Tool schemas use JSON Schema 2020-12. Replace legacy tuple-array `items: [...]`
with `prefixItems`. A supplied explicit older dialect is rejected.

Core enforces its documented portable subset. Use `argument_validator:` for
domain additions and `complete_argument_validator:` only when the host
validator implements the entire schema. Argument-applicable non-empty
`patternProperties` requires complete authority. External references are never
resolved.

Task mode now rejects an assertion Mistri cannot guarantee locally instead of
claiming validated output and leaving part of the schema to provider guidance.
Freeform objects cannot become strict task output without changing meaning.

See [Tool contracts](docs/tool-contracts.md).

### Schema objects are canonical and immutable

`Tool#input_schema` and `Schema.strict` now expose deeply frozen canonical JSON
with String keys. Replace Symbol-key access and mutation:

```ruby
# Before
tool.input_schema[:properties][:account_id] = rule

# After
account_schema = tool.input_schema.fetch("properties").fetch("account_id")
```

Build a new schema when the host needs a changed contract. `Tool.define` now
rejects supplying both `schema:` and `input_schema:`; choose one. Calling
`Schema.build` without a block now raises because it declares no argument
intent.

## Arguments are immutable and policy sees validated types

Completed arguments and the canonical schema are deeply frozen. Code that
mutated model input must copy the portion it owns:

```ruby
# Before: mutates the value shared with policy and replay.
args["tags"] << "processed"

# After: build application-owned data.
tags = args.fetch("tags", []).dup
tags << "processed"
```

For a fully mutable JSON copy:

```ruby
owned = JSON.parse(JSON.generate(args))
```

Approval predicates can now rely on declared types. Remove defensive coercion
that changes authorization meaning:

```ruby
# Do not turn "all" into zero at an authorization boundary.
approval_policy = ->(args) { args.fetch("total_usd") > 500 }
```

When a host intentionally accepts a legacy alias or representation, use
`argument_normalizer:`. Its output is what validation, policy, approval, and
the handler see. It runs once before validation and does not run again on
resume.

Direct `Tool#call` remains a trusted host path. It applies the tool's normalizer
but does not invoke the Agent's model-input validation boundary.

## Tool lifecycle and event subscribers

Tool results now carry a structured error fact. A handler may return
`Mistri::ToolResult.new(content: ..., error: true)`, and Mistri sets the same
fact for invalid, blocked, unknown, interrupted, timed-out, or failed calls.

`:tool_started` is emitted only when a resolved call commits to handler
invocation. `:tool_result` always carries a boolean `event.tool_error`; new
persisted tool messages carry the same value. Legacy messages without the field
remain unknown rather than being classified from prose.

`:tool_started` and handler progress callbacks originate on tool worker threads.
Custom sinks must be thread-safe. Code that manually constructs a
`:tool_result` `Mistri::Event` must now supply a boolean `tool_error` matching
the Message.

An exception from a synchronous subscriber now propagates unchanged from
`run` or `resume`. Mistri does not retry it or reinterpret it as a provider,
transport, hook, tool, parse, or compaction failure. Delivery is not a
transaction: some events follow durable Session appends, and handler progress
can follow an external side effect. Catch subscriber failures at the host
boundary, reconcile the Session and the tool's domain idempotency state, and
retry only under host policy. See [Reliability](docs/reliability.md#events-and-sinks).

Update exhaustive event switches to ignore unknown future members:

```ruby
case event.type
when :text_delta
  stream(event.delta)
when :tool_started
  mark_running(event.tool_call)
when :tool_result
  settle(event.tool_call, failed: event.tool_error)
else
  # Event types are an extensible union.
end
```

Do not decide failure by matching prefixes such as `"Error:"`. Human denial is
an expected control result and is not marked as execution failure.

Missing documents in `read_file`, `find_in_file`, and `edit_file`, plus an
`edit_file` replacement that cannot be applied, now carry `tool_error: true`.
Their actionable model-facing text is unchanged.

The error fact never authorizes mechanical replay. A handler can commit a side
effect before it raises.

Public value records gained fields: `ToolCall` adds `arguments_error` and
`provider_call_id`, `ToolResult` adds `error`, and Message/Event records add
`tool_error`. Keyword construction remains compatible through defaults, but
exact positional deconstruction or pattern matching can break. Prefer named
accessors and key patterns, and treat value and event records as extensible.

## Custom provider contract

Built-in providers already satisfy the new envelope. A custom provider must
return completed `Mistri::ToolCall` values with:

- a non-empty, valid UTF-8 String ID;
- an ID unique for new calls over the active Session;
- a non-empty, valid UTF-8 String name;
- a JSON object for valid arguments, or a durable `arguments_error` for
  malformed encoded input;
- non-empty valid UTF-8 signature and provider call ID strings when present;
- provider correlation IDs unique within an assistant turn.

If any completed call makes the assistant turn unpairable, Mistri rejects the
whole provider attempt before persistence, policy, or sibling execution. The
ordinary provider retry asks for a clean turn with unchanged history.

`ToolCall#arguments_error?` is the stable predicate. Its non-nil String is an
opaque diagnostic, not a public enum.

Audit active custom-provider sessions without mutating them:

```ruby
active_session_ids.each do |session_id|
  session = Mistri::Session.new(store: store, id: session_id)
  session.tool_control_state # validates persisted call and approval identity
end
```

The legacy repeated `call_N` exception is deliberately limited to settled 0.5
Gemini and Fake-provider history without provider correlation IDs. Do not copy
that shape into a custom provider.

Fake-provider call IDs are now namespaced instead of restarting at `call_1`,
`call_2`, and so on. Script an explicit `id:` when a test or persisted fixture
needs deterministic identity.

If an old custom log contains malformed IDs that cannot be paired safely, keep
the old application version available long enough to complete or retire that
session according to host policy. Do not invent replacement IDs in replay; they
would corrupt tool-result correlation.

## Approval decisions are single-assignment

The first valid approval decision in the Session store's durable order is
final. Repeating the same `approve` or `deny` call is idempotent and does not add
another entry once the winner is visible. The first note also wins. A later
conflicting call raises `Mistri::ConfigurationError`; it cannot revoke the
winner.

Two callers can still read the parked request before either appends. Both
attempts may therefore appear in the raw append-only log. Mistri re-reads the
ordered history after append so the winner returns normally and a conflicting
loser raises. Losing entries are validated but inert, including a stale loser
that arrives after the tool result. They no longer make the Session require a
repair step.

This is single-assignment, not quorum. If two people must agree, or a denial
must outrank an approval, implement that policy transactionally in the host and
call Session only after the host has one final decision. A custom Session store
must make a successful append visible to subsequent loads while preserving its
stable total order.

## Session stores

### MySQL and Trilogy payload width

The generated Active Record session table now uses LONGTEXT for `payload`. An
existing table is not changed by updating the generator:

```ruby
class WidenAgentEntryPayload < ActiveRecord::Migration[7.2]
  def change
    change_column :agent_entries, :payload, :text, size: :long, null: false
  end
end
```

Use the migration version appropriate for the host application. PostgreSQL
`text` needs no width change.

### Store value ownership

`Mistri::Stores::Memory` now owns data on append and returns fresh mutable
snapshots on load, matching stores that decode JSON on every read. A custom
store should not rely on Mistri mutating a previously returned entry object.

### Active Session execution

Mistri does not lease top-level Session execution. The host must ensure that at
most one `run` or `resume` is active for a Session across all processes.
Concurrent-safe store appends and child lock adapters do not provide this
guarantee. Keep external writes idempotent or reconcilable across the
handler-commit/result-append gap.

`Session#entries` and serialized usage are extensible records. Raw host readers
must ignore unknown entry types and keys. This release adds lifecycle, approval
provenance, unpriced-attempt, and `cost.known` data.

## Workspace editing and conditional writes

`edit_file` now uses conditional writes when a workspace explicitly advertises
`atomic_writes?`. Existing custom workspaces that implement only `read`,
`write`, `delete`, and `list` keep their 0.5 behavior. A custom workspace must
claim atomic support only when its `snapshot` and `compare_and_write` methods
satisfy the complete contract in
[Context and workspaces](docs/context-and-workspaces.md#workspaces-and-document-tools).

Only anchored `edit_file` uses this protocol. `write_file` remains an
intentional blind whole-document replacement, and deletion has no conditional
form. Use an anchored edit or a host tool with a stronger domain contract when
concurrent writers must preserve unrelated changes.

A qualifying `Mistri::Workspace::ActiveRecord` now takes the conditional path
on PostgreSQL, or on an InnoDB table through MySQL2 or Trilogy. It verifies the
primary key, non-null path, content, and scope columns, and an exact unique
scope/path index before advertising the capability. Atomic snapshots and edits
reject when the connection already has an open host transaction, because the
adapter cannot safely join that transaction's isolation and lock lifetime. Run
the Agent outside the host transaction. Unsupported storage retains the legacy
path; assert `workspace.atomic_writes?` at boot rather than accepting that
fallback when lost-update protection is required.

`Mistri::Workspace::Memory#read` now returns an owned copy. Call `write` to
persist a changed value; mutating a previously returned String no longer changes
workspace state. Its conditional writes protect only threads sharing that
Memory instance, not separate processes.

`Mistri::Workspace::Single` opts in only when given `synchronize:`. That
callback must cover the complete current read, revision check, write, and
committed read for every competing writer. It must also refuse an already-open
Active Record transaction when it uses an Active Record lock. Without the
callback, Single keeps its legacy four-method behavior.

## MCP changes

### Existing generated OAuth models

The 0.5 Rails MCP generator stored `token_endpoint`. The current flow persists
the authorization-server `issuer` and rediscovers the token endpoint from that
exact identity before code exchange and refresh.

For an existing generated model:

1. Add an `issuer` String column.
2. Persist `flow["issuer"]` in `connect` instead of trusting
   `flow["token_endpoint"]`.
3. Pass `issuer:` to `OAuth.complete` and `OAuth.refresh`.
4. Keep and pass `token_auth_method`.
5. Add one class-owned `mcp_allow_non_public` policy and pass it to
   `OAuth.start`, `.complete`, `.refresh`, and `MCP::Client` when internal
   destinations are allowed.
6. Restart pending OAuth flows.
7. Reconnect existing rows unless the application independently recorded the
   exact issuer used during registration.

Mistri no longer adds `offline_access`; include it explicitly in `scope:` only
when host policy and the authorization server require it. The former implicit
localhost allowance is also gone. Loopback HTTP development now needs an
explicit `allow_non_public: ->(_uri, address) { address.loopback? }` through the
complete flow. A pre-registered client, or discovery advertising multiple
authorization servers, requires the exact trusted `issuer:`.

Never infer an issuer from a token endpoint. They are different security
identities. An unused legacy `token_endpoint` column may be removed in a later
host migration after rollback needs have passed.

Compare the generated files in
[`lib/generators/mistri/mcp/templates/`](lib/generators/mistri/mcp/templates)
with the host copy. Updating the gem never rewrites generated application code.

### Network policy

Remote MCP and server-side OAuth now default to public HTTPS, validated DNS,
direct connections, no redirects, and no ambient proxy. An internal server must
receive the same narrow `allow_non_public:` callback through the entire flow.

Custom headers are copied when the Client is constructed, and transport-owned
framing, MCP session, and protocol names are rejected. Use the token callable for
rotating authorization. Deployments that require an ambient forward proxy or
HTTP redirects need a host-supplied client; the built-in Client deliberately
connects directly.

### Response limits and delivery

JSON bodies, individual SSE lines, and stdio records default to 8 MiB per
record. Set a larger `max_record_bytes:` only for a trusted server after
reviewing the memory boundary.

Provider records use `provider_options: { max_record_bytes: ... }`; the MCP
Client takes `max_record_bytes:` directly. Servers exceeding the new default of
100 discovery pages or 10,000 tools must set reviewed `max_tool_pages:` and
`max_tools:` values explicitly.

An unconfirmed `tools/call` response now raises
`Mistri::AmbiguousDeliveryError` and is never replayed automatically. Catch it
when calling the Client directly, mark the operation for reconciliation, and
verify remote state before deciding whether a new call is safe. A Client used
through `Mistri::MCP.tools` raises inside the tool executor, which returns the
same uncertainty as an error-marked tool result. The transport still does not
replay it, but the model may choose to issue a new call.

### MCP schemas

Mistri enforces directly reachable portable assertions and lets the MCP server
enforce standard assertions outside that subset. Common map schemas with
schema-valued `additionalProperties` work in core. Use a complete validator only
when local policy depends on the whole schema.

An explicit `inputSchema: null` now rejects. Omit `inputSchema` for a closed
no-argument tool, or provide an object schema.

See [MCP](docs/mcp.md).

## Cost budgets and pricing

0.5 exposed a cost budget but did not calculate provider cost, so the comparison
effectively saw zero. 0.6 prices catalogued standard paid direct-API usage and
represents unknown cost as unknown.

A `cost_usd` budget now fails at construction unless the model, origin, and
service-tier policy can produce deterministic catalog pricing. Configure:

```ruby
# Anthropic
anthropic_options = { service_tier: "standard_only" }

# OpenAI
openai_options = { service_tier: "default" }
```

Gemini's omitted tier is standard. Flex, Priority, an unreported nonstandard
tier, an unknown model, or a custom origin remains unpriced unless the custom
provider supplies complete known cost.

Without a cost budget, unknown models and custom origins continue to work.
Inspect `result.usage.cost.known?` before presenting an estimate.

Budgets remain soft ceilings checked between model-visible turns. A final turn
and its retries may cross the configured amount.

## Compaction behavior

Catalogued Anthropic and OpenAI windows now use their published long-context
limits. Automatic reserve protects the model's full shared output capacity plus
framing slack; Gemini keeps its separately published input-oriented reserve.

Sessions with default compaction will therefore compact at different and more
accurate boundaries. An explicit `reserve:` remains host policy and wins.

Compaction can occur more than once inside one run while preserving tool-call
pairing. The full entry log remains exact; replay after a successful compaction
intentionally becomes the visible summary plus kept tail.

Review any UI or alerting code that assumed the old early thresholds. Only the
`:compaction` event carries the summary; `:compacting` is the start signal.

## Provider refusal and stream behavior

Documented provider refusals, content-policy stops, and invalid requests now
fail fast instead of looking like clean completion or consuming retries on the
same rejected input. Unknown transient stream failures still follow the retry
policy.

Interrupted tool calls and partial Anthropic thinking signatures are removed
before persistence. Built-in stream assemblers now enforce known lifecycle,
index, and terminal-record invariants while ignoring unknown future event types
for forward compatibility.

If host code classified provider errors by prose, move to the typed
`result.errored?`, `result.message.error`, `result.stop_reason`, and structured
event or message fields. Built-in provider refusals finish in the Result
contract; they are not raised as ordinary transport exceptions.

## Directory workspaces

Directory workspaces no longer follow existing symlinks in model-controlled
paths and omit symlinked entries from listings. Replace intentional links with
host-controlled tools or real files inside the workspace root. This boundary is
deliberate and has no opt-out in the model-controlled file tools.

## Verification before production

At minimum:

1. Run the hermetic suite and application tests.
2. Audit active persisted sessions with `tool_control_state`.
3. Resume a 0.5 Anthropic session with tool calls and reasoning.
4. Resume a 0.5 Gemini session containing tool calls from more than one turn.
5. Exercise one approval grant and denial after rebuilding current policy.
6. Run a write tool with an idempotency key and simulate failure before result
   persistence in the host test harness.
7. Reconnect and refresh one MCP OAuth connection.
8. For a workspace that requires concurrent edit preservation, assert
   `atomic_writes?` and race two anchored edits against its real backend.
9. Run the provider-specific live tests and integration matrix with every
   expected key present.

```console
$ bundle exec rake test
$ bundle exec rubocop
$ MISTRI_LIVE=1 bundle exec rake test
$ MISTRI_INTEGRATION_STRICT=1 bundle exec rake integration
```

Ordinary integration runs skip missing provider keys and an unreachable public
MCP fixture. Strict mode fails when a matrix key is absent or that fixture is
unavailable, so use it for release verification.

For exact behavior and latency notes, read the
[0.6.0 changelog entry](CHANGELOG.md#060---2026-07-12).
