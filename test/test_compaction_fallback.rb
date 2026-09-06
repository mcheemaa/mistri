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

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
