# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/scripted_sandbox"

# What code read or wrote is kept in the session, so a later run of code
# writes over a document at the version an earlier run left there.
class TestCodeDocuments < Minitest::Test
  PATH = "scratchpad/notes.md"
  SAVED = "scratchpad/tool-results/saved.txt"

  def setup
    @store = Mistri::Stores::Memory.new
    @workspace = Mistri::Workspace::Memory.new
  end

  def test_a_later_run_writes_over_a_document_an_earlier_run_wrote
    replies = runs([write("first")], [write("second")])

    assert_equal [[nil], [nil]], replies
    assert_equal "second", @workspace.read(PATH)
  end

  def test_a_read_in_one_run_lets_a_later_run_write
    @workspace.write(PATH, "by a person")

    replies = runs([["read", { "path" => PATH }]], [write("mine")])

    assert_equal [["by a person"], [nil]], replies
    assert_equal "mine", @workspace.read(PATH)
  end

  def test_a_document_someone_else_changed_is_refused_until_code_reads_it
    runs([write("first")])
    @workspace.write(PATH, "changed by a person")

    refused, read, written = runs([write("second")], [["read", { "path" => PATH }]],
                                  [write("third")]).flatten

    assert_match(/changed since\. Nothing was written\. Read it with files\.read/, refused)
    assert_equal "changed by a person", read
    assert_nil written
    assert_equal "third", @workspace.read(PATH)
  end

  def test_what_code_wrote_is_remembered_after_a_restart
    runs([write("first")])

    assert_equal [[nil]], runs([write("second")])
    assert_equal "second", @workspace.read(PATH)
  end

  def test_what_code_wrote_is_remembered_across_a_compaction
    runs([write("first")])
    session.checkpoint(summary: "Earlier work.", kept_from: session.entries.length)

    assert_equal [[PATH, Mistri::Tools.version("first")]],
                 session.last_compaction.dig("carried", "code_documents")
    assert_equal [[nil]], runs([write("second")])
  end

  def test_a_run_that_is_stopped_still_leaves_what_it_wrote
    stopped = Class.new do
      def run(code, host:)
        JSON.parse(code).each { |operation, payload| host.call(operation, payload) }
        raise Mistri::Sandbox::Stopped, "the code was stopped"
      end
    end.new

    assert_equal ["The code did not finish: the code was stopped"],
                 results([write("first")], sandbox: stopped)
    assert_equal [[nil]], runs([write("second")])
  end

  def test_a_run_leaves_an_entry_only_for_what_it_learned
    @workspace.write(SAVED, "a saved result")

    runs([write("first")], [["read", { "path" => PATH }], ["read", { "path" => SAVED }]])
    entries = session.entries.select { |entry| entry["type"] == "code_documents" }

    assert_equal([[[PATH, Mistri::Tools.version("first")]]],
                 entries.map { |entry| entry["versions"] })
  end

  def test_the_session_keeps_the_newest_thousand_documents
    session.remember_code_documents((1..1_100).map { |n| ["notes/#{n}.md", "v#{n}"] })
    session.remember_code_documents([["notes/1101.md", "v1101"], ["notes/500.md", "again"]])

    known = session.code_documents

    assert_equal 1_000, known.size
    assert_equal %w[notes/102.md notes/500.md], [known.keys.first, known.keys.last]
    assert_equal "again", known["notes/500.md"]
  end

  private

  def session = Mistri::Session.new(store: @store, id: "notes")

  def write(content) = ["write", { "path" => PATH, "content" => content }]

  def runs(*scripts)
    results(*scripts).map { |text| JSON.parse(text.lines.last) }
  end

  # One agent runs each script in a turn of its own. Every call builds a new
  # agent on a new Session over the same store, as a host does after a restart.
  def results(*scripts, sandbox: Mistri::Test::ScriptedSandbox.new)
    turns = scripts.map do |script|
      { tool_calls: [{ name: "run_code", arguments: { code: JSON.generate(script) } }] }
    end
    provider = Mistri::Providers::Fake.new(turns: [*turns, { text: "done" }])
    agent = Mistri::Agent.new(provider:, session:, scratchpad: @workspace, sandbox:)
    agent.run("go")
    agent.session.messages.select(&:tool?).last(scripts.length).map(&:text)
  end
end
