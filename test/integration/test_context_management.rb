# frozen_string_literal: true

require_relative "../support/integration"

# Long-run survival: compaction preserves generated facts through its own
# summary, skills load on demand, and memory persists what it is told.
class TestContextManagementIntegration < Minitest::Test
  Integration.scenario(self, :compaction_preserves_facts_through_the_summary) do |model|
    title = Integration.codename
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    settings = Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 20)
    agent = Mistri::Agent.new(provider: Mistri.provider(model), session:,
                              compaction: settings, system: "You keep project notes. Be brief.")

    notes = "Project notes: the launch playlist is titled #{title}, the venue is " \
            "Aurora Hall, and the sponsor is Kestrel Labs. Acknowledge briefly."
    agent.run(notes)
    result = agent.run("Quick check: what is the launch playlist titled?")

    assert session.entries.any? { |e| e["type"] == "compaction" }, "compaction never fired"
    assert(session.messages.none? { |m| m.text == notes },
           "the original message should have left the replay")
    assert Integration.saw?(result.text, title),
           "the fact did not survive compaction: #{result.text}"
  end

  Integration.scenario(self, :skills_load_on_demand_and_bind) do |model|
    suffix = Integration.codename
    skills = [Mistri::Skill.new(
      name: "brand-voice",
      description: "Rules for writing any customer-facing copy or taglines.",
      body: "House voice: short sentences. Every tagline MUST end with " \
            "the exact suffix ' | #{suffix}'."
    )]
    reads = []
    agent = Mistri::Agent.new(provider: Mistri.provider(model), skills:,
                              system: "You write landing page copy.")

    result = agent.run("Write a one-line tagline for a developer conference.") do |e|
      reads << e.tool_call.name if e.type == :tool_result
    end

    assert_includes reads, "read_skill", "the model never pulled the skill body"
    assert Integration.saw?(result.text, suffix), "the skill's rule never applied"
  end

  Integration.scenario(self, :memory_persists_what_it_is_told) do |model|
    mascot = Integration.codename
    saved = +""
    memory = Mistri::Memory.new(read: -> { saved }, write: ->(text) { saved.replace(text) })
    agent = Mistri::Agent.new(provider: Mistri.provider(model),
                              tools: Mistri::Tools.memory(memory),
                              system: "Keep your memory document up to date when asked.")

    result = agent.run("Record in memory that the project mascot is named #{mascot}.")

    assert_predicate result, :completed?
    assert Integration.saw?(saved, mascot), "memory never got the fact: #{saved.inspect}"
  end
end
