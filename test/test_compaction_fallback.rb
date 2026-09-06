# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

# A host-chosen fallback gets one try when the session's provider cannot write
# a usable summary; nothing else changes about what a checkpoint may replace.
class TestCompactionFallback < Minitest::Test
  SETTINGS = { window: 600, reserve: 550, keep_recent: 10 }.freeze
  PRIMARY_USAGE = Mistri::Usage.new(input: 1_000, output: 48).with_cost(input: 1.0, output: 5.0)
  FALLBACK_USAGE = Mistri::Usage.new(input: 1_100, output: 300).with_cost(input: 1.0, output: 5.0)

  def test_the_fallback_is_not_asked_when_the_primary_summary_is_usable
    fallback = fake_fallback
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Checkpoint.", usage: PRIMARY_USAGE }])
    session = history

    result = Mistri::Compactor.call(session:, provider:, settings: settings(fallback:))

    assert_equal "Checkpoint.", result[:summary]
    assert_same PRIMARY_USAGE, result[:usage]
    assert_empty fallback.requests
    assert_equal "fake-1", session.last_compaction.fetch("model")
  end

  def test_the_fallback_writes_the_checkpoint_when_the_primary_cannot
    Dir.mktmpdir do |directory|
      store = Mistri::Stores::JSONL.new(directory)
      session = history(store:)
      provider = Mistri::Providers::Fake.new(turns: [incomplete_turn])
      fallback = fake_fallback(turns: [{ text: "Fallback checkpoint.", usage: FALLBACK_USAGE }])
      events = []

      result = Mistri::Compactor.call(session:, provider:, settings: settings(fallback:)) do |event|
        events << event
      end

      assert_equal "Fallback checkpoint.", result[:summary]
      assert_equal PRIMARY_USAGE + FALLBACK_USAGE, result[:usage]
      assert_equal %i[compacting compaction], events.map(&:type)
      assert_equal "fallback-1", events.last.message.model
      assert_equal "fallback-1", session.last_compaction.fetch("model")
      assert_equal 0, session.compaction_failures
      assert_equal provider.requests.first[:messages], fallback.requests.first[:messages]

      reloaded = Mistri::Session.new(store:, id: session.id)

      assert_equal session.messages, reloaded.messages
      assert_includes reloaded.messages.first.text, "Fallback checkpoint."
    end
  end

  def test_both_failures_record_one_attempt_naming_each_model
    session = history
    provider = Mistri::Providers::Fake.new(turns: [incomplete_turn])
    fallback = fake_fallback(turns: [{ error: "summarizer unavailable", usage: FALLBACK_USAGE }])
    events = []

    error = assert_raises(Mistri::CompactionError) do
      Mistri::Compactor.call(session:, provider:, settings: settings(fallback:)) do |event|
        events << event
      end
    end

    reason = "fake-1: unexpected stop reason: :length; fallback-1: summarizer unavailable"

    assert_equal "summarization failed: #{reason}", error.message
    assert_equal PRIMARY_USAGE + FALLBACK_USAGE, error.usage
    assert_equal reason, session.entries.last.fetch("reason")
    assert_equal reason, events.last.error_message
    assert_equal 1, session.compaction_failures
    assert_nil session.last_compaction
  end

  def test_automatic_compaction_spends_one_attempt_when_both_fail
    session = history
    provider = Mistri::Providers::Fake.new(turns: [incomplete_turn, { text: "done" }])
    fallback = fake_fallback(turns: [incomplete_turn])
    compaction = Mistri::Compaction.new(**SETTINGS, fallback:)

    result = Mistri::Agent.new(provider:, session:, compaction:).run("Continue.")

    assert_predicate result, :completed?
    assert_equal PRIMARY_USAGE + PRIMARY_USAGE, result.usage
    assert_equal 1, session.compaction_failures(trigger: :automatic)
    assert_equal 2, provider.requests.length
    assert_equal 1, fallback.requests.length
  end

  def test_an_attempt_without_usage_makes_the_combined_cost_unknown
    [[nil, FALLBACK_USAGE], [PRIMARY_USAGE, nil]].each do |primary_usage, fallback_usage|
      session = history
      provider = scripted(model: "fake-1", replies: [incomplete_reply(usage: primary_usage)])
      fallback = scripted(model: "fallback-1", replies: [checkpoint_reply(usage: fallback_usage)])

      result = Mistri::Compactor.call(session:, provider:, settings: settings(fallback:))

      assert_equal "Checkpoint.", result[:summary]
      refute_predicate result[:usage].cost, :known?
      assert_equal (primary_usage || fallback_usage).input, result[:usage].input
    end
  end

  def test_a_cost_budget_stops_before_the_fallback_when_the_primary_is_unpriced
    session = history
    unpriced = incomplete_reply(usage: Mistri::Usage.new(input: 900))
    provider = scripted(model: "fake-1", replies: [unpriced])
    fallback = fake_fallback(turns: [{ text: "Checkpoint.", usage: FALLBACK_USAGE }])
    compaction = Mistri::Compaction.new(**SETTINGS, fallback:)
    budget = Mistri::Budget.new(cost_usd: 10.0)

    error = assert_raises(Mistri::BudgetError) do
      Mistri::Agent.new(provider:, session:, compaction:, budget:).run("Continue.")
    end
    unpriced_attempts = session.entries.count { |entry| entry["type"] == "unpriced_attempt" }

    assert_includes error.message, "unpriced usage"
    assert_empty fallback.requests
    assert_equal 1, unpriced_attempts
    assert_equal 1, session.compaction_failures(trigger: :automatic)
    assert_equal "budget_cost_unknown", session.messages.last.error_message
  end

  def test_a_cost_budget_rejects_an_unpriced_fallback_at_construction
    provider = Mistri::Providers::Fake.new(turns: [{ text: "done", usage: PRIMARY_USAGE }])
    fallback = fake_fallback(turns: [{ text: "Checkpoint.", usage: Mistri::Usage.new(input: 1) }])
    compaction = Mistri::Compaction.new(**SETTINGS, fallback:)

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider:, compaction:, budget: Mistri::Budget.new(cost_usd: 1.0))
    end

    assert_includes error.message, "fallback-1"
    assert_kind_of Mistri::Agent, Mistri::Agent.new(provider:, compaction:)
  end

  def test_a_fallback_naming_the_primary_model_is_never_asked
    twin = Mistri::Providers::Fake.new(turns: [{ text: "must not run" }])
    provider = Mistri::Providers::Fake.new(turns: [incomplete_turn])

    error = assert_raises(Mistri::CompactionError) do
      Mistri::Compactor.call(session: history, provider:, settings: settings(fallback: twin))
    end

    assert_equal "summarization failed: fake-1: unexpected stop reason: :length", error.message
    assert_empty twin.requests

    provider = Mistri::Providers::Fake.new(turns: [incomplete_turn])

    assert_raises(Mistri::CompactionError) do
      Mistri::Compactor.call(session: history, provider:, settings: settings(fallback: provider))
    end
    assert_equal 1, provider.requests.length
  end

  def test_a_reply_without_a_model_is_attributed_to_the_provider_that_wrote_it
    session = history
    provider = Mistri::Providers::Fake.new(turns: [incomplete_turn])
    fallback = scripted(model: "custom-1", replies: [checkpoint_reply(usage: FALLBACK_USAGE)])
    events = []

    Mistri::Compactor.call(session:, provider:, settings: settings(fallback:)) { |event| events << event }

    assert_equal "custom-1", session.last_compaction.fetch("model")
    assert_equal "custom-1", events.last.message.model
  end

  def test_the_setting_takes_a_provider_or_a_model_id_and_rejects_the_rest
    provider = Mistri::Providers::Fake.new

    assert_same provider, Mistri::Compaction.new(fallback: provider).fallback
    assert_nil Mistri::Compaction.new.fallback
    with_env("ANTHROPIC_API_KEY" => "test") do
      resolved = Mistri::Compaction.new(fallback: "claude-haiku-4-5").fallback

      assert_kind_of Mistri::Providers::Anthropic, resolved
      assert_equal "claude-haiku-4-5", resolved.model
    ensure
      resolved&.close
    end

    with_env("ANTHROPIC_API_KEY" => nil) do
      assert_raises(Mistri::ConfigurationError) { Mistri::Compaction.new(fallback: "claude-haiku-4-5") }
    end
    [:sonnet, 42, Object.new].each do |value|
      error = assert_raises(ArgumentError) { Mistri::Compaction.new(fallback: value) }

      assert_equal "fallback must be a provider or a model id", error.message
    end
  end

  private

  def settings(**overrides)
    Mistri::Compaction.new(**SETTINGS, **overrides)
  end

  def history(store: Mistri::Stores::Memory.new)
    session = Mistri::Session.new(store:)
    session.append_message(Mistri::Message.user("Original export rules. " * 80))
    session.append_message(Mistri::Message.assistant(content: "Source inspected. " * 80,
                                                     stop_reason: :stop))
    session.append_message(Mistri::Message.user("Retain this follow-up. " * 80))
    session
  end

  def incomplete_turn
    { text: "private unfinished summary", stop_reason: :length, usage: PRIMARY_USAGE }
  end

  def fake_fallback(turns: [])
    fallback = Mistri::Providers::Fake.new(turns:)
    fallback.define_singleton_method(:model) { "fallback-1" }
    fallback
  end

  # The minimal custom-provider contract: stream and model, replies as given,
  # with no model or usage metadata the provider did not put there.
  def scripted(model:, replies:)
    provider = Mistri::Providers::Fake.new
    provider.define_singleton_method(:model) { model }
    provider.define_singleton_method(:stream) do |**options|
      requests << { options: }
      replies.shift || raise("no scripted reply left")
    end
    provider
  end

  def incomplete_reply(usage:)
    Mistri::Message.assistant(content: "private unfinished summary", stop_reason: :length, usage:)
  end

  def checkpoint_reply(usage:)
    Mistri::Message.assistant(content: "Checkpoint.", stop_reason: :stop, usage:)
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
