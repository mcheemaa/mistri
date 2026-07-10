# AGENTS.md

Working rules for anyone, human or agent, writing code in this repository.

## What this is

Mistri (مستری) is an agent harness for Ruby applications: Anthropic, OpenAI, and Gemini,
frontier-deep, no terminal UI. The gem owns mechanism; the host application owns policy.
Every feature, dependency, and comment must earn its place.

## Hard quality gates (every commit)

1. `bundle exec rake test` passes. Tests are hermetic by default: no network, no keys.
2. `bundle exec rubocop` is clean. A cop disable carries a one-line reason.
3. New behavior ships with its tests in the same commit.
4. The gemspec declares zero runtime dependencies. A new dependency is a design decision
   with written justification, never a convenience.
5. Streaming paths never buffer a whole response. A change on the hot path (request build,
   SSE read, event emission) states its latency impact.
6. A public API change updates the CHANGELOG Unreleased section in the same commit.
7. `# frozen_string_literal: true` heads every Ruby file.
8. CI is green on main, always. Nothing merges red.

## Comments

Comment the WHY the code cannot say: a constraint, a provider quirk, a deliberate trade-off.
Never narrate what the next line does; a comment on a self-explanatory method is noise.
One lead sentence on each class or module. If a method needs a comment to be understood,
try a better name first. ASCII hyphens only; no em or en dashes anywhere.

## Tests

Four rings:

1. Hermetic (default, CI): Minitest, the fake provider, recorded wire fixtures.
2. Differential: where behavior must match truffle-rb (schema emission, partial JSON,
   SSE framing), assert both against the same inputs.
3. Live (`MISTRI_LIVE=1 bundle exec rake test`): real provider calls. Keys load from
   `.env.development.local`, which is gitignored and never committed.
4. End to end: a demo application drives the full loop in a real browser before a release.

## Commits

Plain sentence case, atomic, present tense: "Add the streaming event union".
No ticket references, no Co-Authored-By, no emojis.

## Releases

Semver from 0.x: patch for fixes, minor for features. Prepare every release on main with
a versioned CHANGELOG entry and matching `vX.Y.Z` tag. The tag-derived workflow verifies,
builds, and publishes through RubyGems trusted publishing; never publish from a branch or
manual dispatch. MFA is mandatory on the publishing account and in the gemspec metadata.

## Review

Every phase gets an adversarial review before it merges: correctness, API design, latency,
and public-gem polish. Findings are fixed or rejected with a stated reason, never dropped.
