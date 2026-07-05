# frozen_string_literal: true

require_relative "../support/integration"

# Sub-agents end to end: facts must flow parent -> child -> tool -> child ->
# parent, with the child's transcript persisted and linked.
class TestDelegationIntegration < Minitest::Test
  Integration.scenario(self, :named_specialist_delegates_and_links) do |model|
    year = rand(1890..1990)
    company = Integration.codename
    store = Mistri::Stores::Memory.new
    archive = Mistri::Tool.define("company_archive", "Company facts lookup.",
                                  schema: lambda {
                                    string :query, "What to look up", required: true
                                  }) do
      "#{company}: founded #{year}; makes falconry drones."
    end
    researcher = Mistri::SubAgent.new(name: "researcher",
                                      description: "Researches companies, reports facts.",
                                      provider: Mistri.provider(model),
                                      system: "Use company_archive. Report tersely.",
                                      tools: [archive])
    origins = []
    parent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [researcher.tool],
                               session: Mistri::Session.new(store:),
                               system: "Delegate research to the researcher.")

    result = parent.run("What year was #{company} founded? One sentence.") do |e|
      origins << e.origin if e.origin
    end

    assert_predicate result, :completed?
    assert Integration.saw?(result.text, year.to_s), "the year never flowed up: #{result.text}"
    assert(origins.all? { |o| o.start_with?("researcher#") }, "child events untagged")

    link = parent.session.messages.select(&:tool?).last.ui
    child = Mistri::Session.new(store:, id: link.fetch("session_id"))

    assert_operator child.messages.length, :>=, 3, "the child transcript should persist"
  end

  Integration.scenario(self, :spawner_delegates_with_written_instructions) do |model|
    company = Integration.codename
    count = rand(40..900)
    archive = Mistri::Tool.define("company_archive", "Company facts lookup.") do
      "#{company} has #{count} employees."
    end
    spawn = Mistri::SubAgent.spawner(provider: Mistri.provider(model), tools: [archive])
    parent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [spawn],
                               system: "Delegate lookups via spawn_agent; keep your " \
                                       "own context clean.")

    result = parent.run("Using a sub-agent, find how many employees #{company} has. " \
                        "One sentence.")

    assert_predicate result, :completed?
    assert(parent.session.entries.any? { |e| e["type"] == "subagent" }, "nothing spawned")
    assert Integration.saw?(result.text, count.to_s), "the count never flowed: #{result.text}"
  end
end
