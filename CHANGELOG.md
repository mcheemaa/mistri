# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- The error hierarchy: every Mistri failure rescues as `Mistri::Error`.
- The message protocol: immutable content blocks (text, thinking, image, tool call),
  messages with provider identity, usage accounting with cost math, stop reasons.
- The streaming event union: twelve event types, each carrying an immutable
  partial-message snapshot.
- `Mistri::Providers::Fake`: a scriptable provider for hermetic host tests.
- `Mistri::AbortSignal`: a thread-safe cancel latch with abort callbacks.
- `Mistri::SSE`: an incremental server-sent-events decoder.
- `Mistri::Transport`: a persistent per-provider streaming connection with
  status-mapped errors and hard abort of hung streams.
- `Mistri::PartialJson`: best-effort parsing of in-flight tool arguments.
- `Mistri::Models`: a capability catalog with graceful passthrough, so unknown
  models work the day they ship.
- `Mistri::Providers::Anthropic`: the Messages API streamed, with adaptive
  thinking, prompt caching, signature round-trips, and eager tool-input
  streaming.
- `Mistri::Providers::OpenAI`: the Responses API streamed and stateless, with
  encrypted reasoning replay and thinking summaries.

## [0.0.3] - 2026-07-04

- Repository moved to github.com/mcheemaa/mistri.
- Development toolchain: Minitest, RuboCop, CI.

## [0.0.1] - 2026-07-04

- Reserved the gem name.
