# frozen_string_literal: true

require_relative "../support/integration"

# Sub-agents end to end: facts must flow parent -> child -> tool -> child ->
# parent, with the child's transcript persisted and linked.
class TestDelegationIntegration < Minitest::Test
  Integration.scenario(self, :named_specialist_delegates_and_links) do |model|
    year = rand(1890..1990)
    company = Integration.codename
    store = Mistri::Stores::Memory.new
    archive = Mistri::Tool.define("company_archive", "Authoritative fictional-company facts.",
                                  schema: lambda {
                                    string :query, "What to look up", required: true
                                  }) do
      "#{company}: founded #{year}; makes falconry drones."
    end
    researcher = Mistri::SubAgent.new(name: "researcher",
                                      description: "Researches companies, reports facts.",
                                      provider: Mistri.provider(model),
                                      system: "Call company_archive for the requested fictional " \
                                              "company. Never use memory or public sources. " \
                                              "Report tersely.",
                                      tools: [archive])
    origins = []
    parent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [researcher.tool],
                               session: Mistri::Session.new(store:),
                               system: "Never answer company questions from memory: " \
                                       "call the researcher and relay what it reports.")

    result = parent.run("For the fictional company #{company}, use the researcher to find " \
                        "its founding year. One sentence.") do |e|
      origins << e.origin if e.origin
    end

    assert_predicate result, :completed?
    assert Integration.number?(result.text, year), "the year never flowed up: #{result.text}"
    lanes = origins.uniq

    assert_equal 1, lanes.length, "one worker, one lane: #{lanes.inspect}"
    assert_match(/\A[\w-]+#\h{8}\z/, lanes.first,
                 "child events carry a worker tag: #{lanes.first.inspect}")

    link = parent.session.messages.select(&:tool?).last.ui
    child = Mistri::Session.new(store:, id: link.fetch("session_id"))

    assert_operator child.messages.length, :>=, 3, "the child transcript should persist"
    assert(child.messages.any? do |message|
      message.tool? && message.tool_name == "company_archive"
    end, "the specialist never called its archive")
  end

  Integration.scenario(self, :spawner_delegates_with_written_instructions) do |model|
    company = Integration.codename
    count = rand(40..900)
    archive = Mistri::Tool.define(
      "company_archive",
      "The authoritative source for generated company facts; call it instead of public sources."
    ) do
      "#{company} has #{count} employees."
    end
    spawn = Mistri::SubAgent.spawner(provider: Mistri.provider(model), tools: [archive])
    parent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [spawn],
                               system: "Delegate company lookups via spawn_agent. Grant " \
                                       "company_archive to the child and instruct it to call " \
                                       "that archive; never answer from memory or public " \
                                       "sources. Keep your own context clean.")
    origins = []

    result = parent.run("Using a sub-agent named headcount-scout, use company_archive to " \
                        "find how many employees #{company} has. One sentence.") do |e|
      origins << e.origin if e.origin
    end

    assert_predicate result, :completed?
    assert(parent.session.entries.any? { |e| e["type"] == "subagent" }, "nothing spawned")
    assert Integration.number?(result.text, count), "the count never flowed: #{result.text}"
    assert(origins.any? { |o| o.start_with?("headcount-scout#") },
           "the chosen name never reached the origin channel: #{origins.uniq}")

    link = parent.session.messages.select(&:tool?).last.ui
    child = Mistri::Session.new(store: parent.session.store, id: link.fetch("session_id"))

    assert(child.messages.any? do |message|
      message.tool? && message.tool_name == "company_archive"
    end, "the spawned worker never called its archive")
  end
end
