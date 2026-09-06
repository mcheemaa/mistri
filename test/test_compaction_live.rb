# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require_relative "test_helper"

# A real output-limit stop must leave the durable conversation usable after reload.
class TestCompactionLive < Minitest::Test
  # Observe the actual wire result without replacing the summarizer or its response.
  class ObservedAnthropic < Mistri::Providers::Anthropic
    attr_reader :reply

    def stream(**)
      @reply = Mistri::Test.retry_transient { super }
    end
  end

  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?

    options = { api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: "claude-haiku-4-5-20251001",
                thinking: { type: "disabled" }, service_tier: "standard_only", read_timeout: 120 }
    @summarizer = ObservedAnthropic.new(**options)
    @provider = Mistri::Providers::Anthropic.new(**options)
  end

  def teardown
    @summarizer&.close
    @provider&.close
  end

  def test_a_truncated_summary_preserves_requirements_for_a_live_continuation
    Dir.mktmpdir do |dir|
      filename = "export-#{SecureRandom.hex(12)}.json"
      session = export_session(dir, filename)
      path = File.join(dir, "#{session.id}.jsonl")
      durable = File.binread(path)
      replay = session.replay
      events = []
      agent = Mistri::Agent.new(provider: @summarizer, session:,
                                compaction: Mistri::Compaction.new(keep_recent: 20, max_tokens: 48))

      error = assert_raises(Mistri::CompactionError) do
        agent.compact { |event| events << event.type }
      end

      assert_equal :length, @summarizer.reply.stop_reason
      refute_empty @summarizer.reply.text.strip
      assert_equal @summarizer.reply.usage, error.usage
      assert_operator error.usage.output, :>, 0
      assert_predicate error.usage.cost, :known?
      assert_operator error.usage.cost.total, :>, 0
      assert_equal %i[compacting compaction_failed], events

      reloaded = Mistri::Session.new(store: Mistri::Stores::JSONL.new(dir), id: session.id)

      assert_failure_appended(path, durable)
      assert_equal 1, reloaded.compaction_failures
      assert_equal replay, reloaded.replay
      assert_nil reloaded.last_compaction
      assert_original_filename(reloaded, filename)
    end
  end

  private

  def assert_failure_appended(path, durable)
    after = File.binread(path)

    assert after.start_with?(durable)
    assert_equal "compaction_failed", JSON.parse(after.delete_prefix(durable)).fetch("type")
  end

  def export_session(dir, filename)
    session = Mistri::Session.new(store: Mistri::Stores::JSONL.new(dir))
    session.append_message(Mistri::Message.user(
                             "Prepare an export of active European customers, sorted by id. " \
                             "Use only id, company, and region fields. The exact export " \
                             "filename must be #{filename}. Do not write the file yet."
                           ))
    session.append_message(Mistri::Message.assistant(
                             content: "Preparation notes: validate the source records, retain " \
                                      "the requested fields, and await permission to export. " * 50,
                             stop_reason: :stop
                           ))
    session.append_message(Mistri::Message.user("Leave the export pending until I return."))
    session.append_message(Mistri::Message.assistant(content: "Ready.", stop_reason: :stop))
    session
  end

  def assert_original_filename(session, filename)
    agent = Mistri::Agent.new(provider: @provider, session:, compaction: false,
                              system: "Return requested identifiers exactly, without formatting.")
    result = agent.run("What exact export filename did I originally request? " \
                       "Reply with that filename only.")

    assert_equal :stop, result.stop_reason
    assert_equal filename, result.text.strip
  end
end
