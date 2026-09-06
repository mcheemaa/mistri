# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require_relative "test_helper"

# A failed primary summary must not end compaction when the host named a
# fallback: a real Haiku writes the checkpoint and a continuation on the
# reloaded session still recalls the original requirement.
class TestCompactionFallbackLive < Minitest::Test
  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?

    @fallback = Mistri::Providers::Anthropic.new(
      api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: "claude-haiku-4-5-20251001",
      thinking: { type: "disabled" }, service_tier: "standard_only", read_timeout: 120
    )
  end

  def teardown
    @fallback&.close
  end

  def test_a_failed_primary_hands_the_checkpoint_to_the_fallback
    Dir.mktmpdir do |dir|
      filename = "export-#{SecureRandom.hex(12)}.json"
      session = export_session(dir, filename)
      primary = Mistri::Providers::Fake.new(turns: [{ error: "the model refused to respond" }])
      settings = Mistri::Compaction.new(keep_recent: 20, fallback: @fallback)
      events = []

      result = Mistri::Compactor.call(session:, provider: primary, settings:) do |event|
        events << event.type
      end

      assert_equal %i[compacting compaction], events
      assert_equal "claude-haiku-4-5-20251001", session.last_compaction.fetch("model")
      assert_operator result[:usage].output, :>, 0
      assert_predicate result[:usage].cost, :known?
      assert_equal 0, session.compaction_failures

      reloaded = Mistri::Session.new(store: Mistri::Stores::JSONL.new(dir), id: session.id)
      question = Mistri::Message.user("Which exact filename must the export use? Reply with " \
                                      "the filename only.")
      reply = Mistri::Test.retry_transient do
        @fallback.stream(messages: reloaded.messages + [question], system: "Answer precisely.")
      end

      assert_equal :stop, reply.stop_reason, reply.error_message
      assert_includes reply.text, filename
    end
  end

  private

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
end
