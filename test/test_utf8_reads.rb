# frozen_string_literal: true

require_relative "test_helper"
require_relative "../eval/compaction"
require "tmpdir"

# A process with no UTF-8 locale (cron, a systemd unit, an image with no
# LANG) reads files as US-ASCII unless told otherwise. What the gem reads
# from disk is UTF-8 wherever it runs.
class TestUtf8Reads < Minitest::Test
  TEXT = "café ✓"

  def setup
    @dir = Dir.mktmpdir
    @external = Encoding.default_external
    self.default_external = Encoding::US_ASCII
  end

  def teardown
    self.default_external = @external
    FileUtils.remove_entry(@dir)
  end

  def test_the_jsonl_store_loads_a_session_with_a_non_ascii_character
    store = Mistri::Stores::JSONL.new(@dir)
    Mistri::Session.new(store:, id: "s").append_message(Mistri::Message.user(TEXT))

    assert_equal [TEXT], Mistri::Session.new(store:, id: "s").messages.map(&:text)
  end

  def test_a_workspace_file_reads_back_as_it_was_written
    workspace = Mistri::Workspace::Directory.new(@dir)
    workspace.write("note.md", TEXT)

    assert_equal TEXT, workspace.read("note.md")
    assert_equal({ "content" => TEXT },
                 JSON.parse(JSON.generate("content" => workspace.read("note.md"))))
  end

  def test_a_skill_with_a_non_ascii_character_loads
    File.binwrite(File.join(@dir, "greet.md"),
                  "---\nname: greet\ndescription: Say #{TEXT}\n---\nSay #{TEXT}.\n")

    skill = Mistri::Skills.load(@dir).first

    assert_equal ["Say #{TEXT}", "Say #{TEXT}."], [skill.description, skill.body.strip]
  end

  def test_a_skill_named_after_a_file_with_a_non_ascii_name_is_found_by_that_name
    File.binwrite(File.join(@dir, "#{TEXT}.md"), "---\ndescription: Coffee\n---\nBrew it.\n")

    skills = Mistri::Skills.load(@dir)
    answer = Mistri::Skills.reader(skills).call({ "name" => TEXT }, nil)

    assert_equal [TEXT], skills.map(&:name)
    assert_match(/Brew it/, answer.to_s)
    assert_includes JSON.parse(JSON.generate(Mistri::Skills.section(skills))), TEXT
  end

  def test_an_eval_report_with_a_non_ascii_character_reads_back
    path = File.join(@dir, "rows.jsonl")
    File.binwrite(path, "#{JSON.generate(scenario: TEXT)}\n")

    assert_equal [{ scenario: TEXT }], CompactionEval::Report.read(path)
  end

  def test_a_definition_with_a_non_ascii_character_loads
    path = File.join(@dir, "agent.md")
    File.binwrite(path, "---\nrole: #{TEXT}\n---\nYou say #{TEXT}.\n")

    definition = Mistri::Definition.load(path)

    assert_equal [TEXT, "You say #{TEXT}."], [definition.role, definition.body]
  end

  private

  # Ruby warns when the default is set at run time.
  def default_external=(encoding)
    verbose = $VERBOSE
    $VERBOSE = nil
    Encoding.default_external = encoding
  ensure
    $VERBOSE = verbose
  end
end
