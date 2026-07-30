# Logging

Assigning `Mistri.logger` makes every run log its story as one line per
meaningful beat: the input, each tool call with its arguments and duration,
each turn's token usage, retries, approvals, compaction, worker reports, and
a closing line with the outcome, elapsed time, and dollar cost whenever
pricing is known.

```ruby
Mistri.logger = Rails.logger   # or any object responding to info/warn/error
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

## Reading the lines

- Every line carries the session tag, so concurrent runs stay separable and
  one run is one grep. Sub-agents log under their own worker label
  (`[mistri researcher#89bb20de]`) exactly once, whichever process runs them.
- A turn line lands when the model finishes speaking, so it precedes the
  tool executions that turn requested.
- The short `#id` on tool lines pairs concurrent same-name calls. An
  `approval needed` line carries the full call id, which is what
  `session.approve` takes.
- Failed tools and retries log at warn and provider errors at error, while
  expected stops (a cancel, a budget ceiling) log calmly at info and warn.
- Cached prompt tokens count toward the tokens in and are called out
  (`900 in (890 cached)`). Dollar cost appears whenever pricing is known,
  including a known $0.0000, which is distinct from unpriced usage.
- A `task` logs one frame around all its fix passes, reporting the validated
  outcome.
- Hidden bytes in any value (control characters, Unicode line separators,
  bidirectional overrides) render as visible escapes, so untrusted output
  cannot forge lines or steer a terminal.

## Options

Assign a preconfigured sink for options; a wrong assignment or option raises
at configuration time rather than leaving the log silently empty.

```ruby
Mistri.logger = Mistri::Sinks::Logger.new(logger, content: false, level: :debug)
```

- `content: false` keeps the whole story as metadata: names, ids, durations,
  sizes, tokens, cost, and statuses. Payloads never appear, and error,
  crash, and retry text reduces to its byte size while classes and reasons
  stay.
- `level:` floors the ordinary lines (pass `:debug` to keep the story out of
  a production logger sitting at `:info`); warnings and errors keep their
  own levels. Formatting is skipped entirely when the floor level is
  disabled on the host logger.
- `truncate:` bounds every rendered value (default 200 characters; `nil`
  for full payloads). Truncated values carry the original payload size.
- `color:` adds ANSI color for terminal viewing; off by default.

By default the lines carry payloads: inputs, thinking, arguments, results.
That is the point in development, and it is a valid production posture too
when your log pipeline is where you want the story; use `content: false`
when payloads must stay out of a log.

## Composing per run

`agent.run(input, &Mistri::Sinks::Logger.new(logger))` delivers the event
lines only, under a bare `[mistri]` tag, with no framing: the run and done
lines come from the Agent, so the composed form has neither. A composed sink
renders forwarded child events with their origin, since no child sink exists
to log them.

## Operational guarantees

- Logging never breaks a run. Sink construction and every write are
  contained; a failing logger warns once per run and that run's sink goes
  quiet. A host exception is never replaced by a logging failure, invalid
  byte sequences included.
- Logger calls are synchronous on the run's own threads, so a slow logger
  slows the run. Keep the destination local (stdout, a file) and let your
  log shipper make the network hop, or buffer at the logger layer.
- With no logger assigned the cost is one nil check per run. With one
  assigned, streaming delta events short-circuit without allocating, and
  per-line string work, tool arguments included, is bounded by the
  truncation limit rather than the payload size.
