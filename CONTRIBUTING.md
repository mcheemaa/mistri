# Contributing

Thanks for wanting to make mistri better.

## Setup

```console
$ bundle install
$ bundle exec rake test      # hermetic, fast, no keys needed
$ bundle exec rubocop
```

The live suites need provider keys in a gitignored `.env.development.local`
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`):

```console
$ MISTRI_LIVE=1 bundle exec rake test      # gated live tests
$ bundle exec rake integration             # critical end-to-end scenarios, per model
```

Missing keys skip their provider. Read the output before treating a live run as
three-provider coverage.

## The rules that keep the gem what it is

- **Zero runtime dependencies.** Development and test dependencies are fine;
  a runtime dependency needs an unusually good reason.
- **Tests ship with the change**, in the same commit. New provider-touching
  behavior gets a live test.
- **Errors follow their boundary.** A tool failure becomes a tool result the
  model can react to. Built-in provider failures finish as an errored Result;
  direct MCP Client and configuration failures raise. A bridged MCP Client
  failure crosses the ordinary tool-result boundary.
- **Sessions are append-only.** Derive state from the entry log; never
  require a repair step after a crash.
- **Comments say why, not what.** Few and load-bearing.
- Run `bundle exec rubocop` before pushing; CI enforces it and a coverage
  floor.

## Pull requests

Small, focused, sentence-case titles. Describe the why in a paragraph, not
a checklist. If the change alters public behavior, add a CHANGELOG entry
under Unreleased.

## Documentation

The README is the adoption path: category, first success, fit, core mechanism,
and honest reliability boundaries. Put detailed contracts in the task-oriented
Markdown guides under `docs/`, and put required host migrations in
`UPGRADING.md`. Link repository files relatively so links work on branches and
pull requests. Do not duplicate the changelog into a guide.
