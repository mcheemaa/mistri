# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Skills: descriptions ride the system prompt for selection; full bodies load
# on demand through the read_skill tool.
class TestSkills < Minitest::Test
  def write_library(dir)
    FileUtils.mkdir_p(File.join(dir, "brand-voice"))
    File.write(File.join(dir, "brand-voice", "SKILL.md"), <<~MD)
      ---
      description: "How to write copy in the house voice."
      ---

      Always end taglines with the sponsor name.
    MD
    File.write(File.join(dir, "seo.md"), <<~MD)
      ---
      name: seo-basics
      description: Meta and heading rules.
      ---
      One h1 per page.
    MD
  end

  def test_load_reads_both_layouts_with_frontmatter
    Dir.mktmpdir do |dir|
      write_library(dir)
      skills = Mistri::Skills.load(dir)

      assert_equal %w[brand-voice seo-basics], skills.map(&:name)
      assert_equal "How to write copy in the house voice.", skills.first.description
      assert_equal "Always end taglines with the sponsor name.", skills.first.body.strip
      assert_equal "One h1 per page.", skills.last.body.strip
    end
  end

  def test_a_missing_directory_fails_loudly
    assert_raises(Mistri::ConfigurationError) { Mistri::Skills.load("/nowhere/skills") }
  end

  def test_a_file_without_frontmatter_is_all_body
    meta, body = Mistri::Skills.parse("Just the playbook.\n")

    assert_empty meta
    assert_equal "Just the playbook.\n", body
  end

  def test_skill_descriptions_join_the_system_prompt
    provider = Mistri::Providers::Fake.new(turns: [{ text: "ok" }])
    skills = [Mistri::Skill.new(name: "brand-voice", description: "House voice rules.")]

    Mistri::Agent.new(provider:, system: "Be brief.", skills:).run("go")

    sent = provider.requests.last[:options][:system]

    assert_includes sent, "Be brief."
    assert_includes sent, "## Skills"
    assert_includes sent, "- brand-voice: House voice rules."
  end

  def test_read_skill_serves_the_body_and_unknown_names_answer_in_band
    turns = [{ tool_calls: [{ name: "read_skill", arguments: { "name" => "brand-voice" } }] },
             { tool_calls: [{ name: "read_skill", arguments: { "name" => "nope" } }] },
             { text: "done" }]
    provider = Mistri::Providers::Fake.new(turns:)
    skills = [Mistri::Skill.new(name: "brand-voice", description: "Voice.",
                                body: "End with the sponsor name.")]
    agent = Mistri::Agent.new(provider:, skills:)

    agent.run("write copy")

    results = agent.session.messages.select(&:tool?).map(&:text)

    assert_equal "End with the sponsor name.", results.first
    assert_includes results.last, 'Unknown skill "nope"'
    assert_includes results.last, "brand-voice"
  end

  def test_skills_accepts_a_directory_path
    Dir.mktmpdir do |dir|
      write_library(dir)
      provider = Mistri::Providers::Fake.new(turns: [{ text: "ok" }])

      Mistri::Agent.new(provider:, skills: dir).run("go")

      assert_includes provider.requests.last[:options][:system], "seo-basics"
    end
  end

  def test_a_host_tool_named_read_skill_collides_loudly
    provider = Mistri::Providers::Fake.new
    mine = Mistri::Tool.define("read_skill", "Mine.") { "x" }

    assert_raises(Mistri::ConfigurationError) do
      Mistri::Agent.new(provider:, tools: [mine],
                        skills: [Mistri::Skill.new(name: "a", description: "b")])
    end
  end

  def test_no_skills_means_no_section_and_no_tool
    provider = Mistri::Providers::Fake.new(turns: [{ text: "ok" }])

    Mistri::Agent.new(provider:, system: "Be brief.").run("go")

    request = provider.requests.last

    assert_equal "Be brief.", request[:options][:system]
    assert_empty request[:options][:tools]
  end

  def test_a_nameless_skill_refuses_construction
    assert_raises(Mistri::ConfigurationError) { Mistri::Skill.new(name: "") }
  end
end
