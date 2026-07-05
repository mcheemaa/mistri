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
$ bundle exec rake integration             # every feature, end to end, per model
```

## The rules that keep the gem what it is

- **Zero runtime dependencies.** Development and test dependencies are fine;
  a runtime dependency needs an unusually good reason.
- **Tests ship with the change**, in the same commit. New provider-touching
  behavior gets a live test.
- **Errors are in-band for the model, raised for the host.** A tool failure
  becomes a tool result the model can react to; configuration and transport
  failures raise a `Mistri::Error` subclass.
- **Sessions are append-only.** Derive state from the entry log; never
  require a repair step after a crash.
- **Comments say why, not what.** Few and load-bearing.
- Run `bundle exec rubocop` before pushing; CI enforces it and a coverage
  floor.

## Pull requests

Small, focused, sentence-case titles. Describe the why in a paragraph, not
a checklist. If the change alters public behavior, add a CHANGELOG entry
under Unreleased.
