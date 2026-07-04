# Mistri

**Mistri (مستری)** is the fixer: the skilled tradesperson you call when something needs building or repairing, the one who actually gets it done. Mistri is an agent harness for Ruby applications, meant to live inside your app rather than run in a terminal.

- **Three providers, frontier-deep.** Anthropic, OpenAI, and Google Gemini, each streamed, with thinking, prompt caching, and tool calling handled natively per provider.
- **One message model.** Write your tools and read the conversation the same way regardless of which model runs.
- **Built for applications.** Sessions persist to your own database, runs stop and resume cleanly, and everything streams so a user watches work happen instead of waiting.
- **Near-zero dependencies.** The core has no runtime gem dependencies.

> Status: early. The API may still change before 1.0.

## Install

```ruby
gem "mistri"
```

## Sixty-second start

```ruby
require "mistri"

agent = Mistri.agent("claude-opus-4-8")          # reads ANTHROPIC_API_KEY from the environment
message = agent.run("Name three Ruby web frameworks.")
puts message.text
```

`Mistri.agent` infers the provider from the model id (`claude-*`, `gpt-*`, `gemini-*`) and reads the matching key (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`). Pass `api_key:` to set it explicitly.

## Streaming

Every run streams. Pass a block to see events as they arrive: text and thinking deltas, tool calls, and a terminal event.

```ruby
agent.run("Explain prompt caching in two sentences.") do |event|
  print event.delta if event.type == :text_delta
end
```

## Tools

A tool is a name, a description, an argument schema, and a block. The block receives the parsed arguments (string keys) and returns a String, a Hash (sent as JSON), or content such as an image.

```ruby
weather = Mistri::Tool.define("get_weather", "Current weather for a city.", schema: lambda {
  string :city, "City name", required: true
  string :units, "Temperature units", enum: %w[celsius fahrenheit]
}) do |args|
  Weather.for(args["city"], units: args["units"] || "celsius")
end

agent = Mistri.agent("gpt-5.5", tools: [weather])
agent.run("What should I wear in Lahore today?")
```

The agent calls tools, feeds the results back, and loops until it answers, all in one `run`. Independent tool calls in a turn run in parallel. If you would rather hand-write the JSON Schema, pass `input_schema:` instead of a `schema:` block.

## Sessions

A session is the durable record of a run. By default it lives in memory; point it at a store to persist and resume.

```ruby
store = Mistri::Stores::JSONL.new("tmp/sessions")
session = Mistri::Session.new(store:)

agent = Mistri.agent("claude-opus-4-8", session:)
agent.run("Start a haiku about the sea.")

# Later, even in another process: reload by id and continue.
resumed = Mistri.agent("claude-opus-4-8", session: Mistri::Session.new(store:, id: session.id))
resumed.run("Now finish it.")
```

### Storing sessions in your database

Ship your own model and hand Mistri the ActiveRecord adapter. Sessions then live wherever your app data lives (MySQL, Postgres, whatever you run).

```ruby
# db migration
create_table :mistri_entries do |t|
  t.string  :session_id, null: false, index: true
  t.integer :position,   null: false
  t.text    :payload,    null: false
  t.timestamps
end

# app
require "mistri/stores/active_record"
class MistriEntry < ApplicationRecord; end

store = Mistri::Stores::ActiveRecord.new(MistriEntry)
agent = Mistri.agent("claude-opus-4-8", session: Mistri::Session.new(store:))
```

## Stopping a run

Pass an abort signal. Trip it from anywhere (a background thread, a "stop" button); an in-flight stream is closed at once, and the partial turn is saved so the next message continues cleanly with no repair.

```ruby
signal = Mistri::AbortSignal.new
Thread.new { sleep 5; signal.abort!(:user_stopped) }

agent.run("Draft a long essay about the sea.", signal:) { |event| render(event) }
# Later, on the same session:
agent.run("Actually, make it about mountains instead.")
```

## Budgets

Budgets are optional and off by default. Set only the ceilings you want; a run finishes the turn it is in, then stops.

```ruby
agent = Mistri.agent("claude-opus-4-8", tools: tools,
                     budget: Mistri::Budget.new(turns: 20, cost_usd: 2.00, wall_clock: 120))
```

## Images

Send images on a user turn; a tool can return one too.

```ruby
photo = Mistri::Content::Image.from_bytes(File.binread("chart.png"), mime_type: "image/png")
agent.run("What trend does this chart show?", images: [photo])
```

## Configuration per provider

`Mistri.agent` forwards provider options through `provider_options:`.

```ruby
Mistri.agent("gpt-5.5", provider_options: { reasoning: { effort: "high" } })
Mistri.agent("claude-opus-4-8", provider_options: { cache: false })
```

## Credits

Mistri's architecture is informed by [pi](https://github.com/badlogic/pi-mono) by Mario Zechner. See NOTICE.

## License

MIT. See LICENSE.
