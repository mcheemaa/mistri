# frozen_string_literal: true

require_relative "../support/integration"

# The management console driven by a real model: spawn a worker, then read
# it and list it through the console tools, and relay what they said.
class TestConsoleIntegration < Minitest::Test
  Integration.scenario(self, :model_reads_and_lists_its_worker) do |model|
    number = rand(100..900)
    store = Mistri::Stores::Memory.new
    oracle = Mistri::Tool.define("oracle", "Answers the secret number.") { number.to_s }
    spawn = Mistri::SubAgent.spawner(provider: Mistri.provider(model), tools: [oracle])
    parent = Mistri::Agent.new(
      provider: Mistri.provider(model),
      tools: [spawn, *Mistri::Console.tools],
      session: Mistri::Session.new(store:),
      system: "Delegate lookups to spawned workers. After a worker finishes, " \
              "verify with read_agent before answering, and check list_agents " \
              "to report its status."
    )

    result = parent.run(
      "Spawn one worker named Beagle (instructions: call the oracle tool and " \
      "report its answer) with the task of fetching the secret number. Then " \
      "read Beagle with read_agent and list your workers, and tell me the " \
      "secret number and Beagle's status in one sentence."
    )

    assert_predicate result, :completed?
    assert Integration.saw?(result.text, number.to_s),
           "the number never surfaced: #{result.text}"
    assert_match(/done|complete|finish/, result.text.to_s.downcase,
                 "the status never surfaced: #{result.text}")

    child = parent.session.children.first

    assert_equal "Beagle", child.name
    assert_equal :done, child.status

    tool_names = parent.session.messages.select(&:assistant?)
                       .flat_map(&:tool_calls).map(&:name)

    assert_includes tool_names, "read_agent", "the model must actually use the console"
    assert_includes tool_names, "list_agents", "the model must actually use the console"
  end
end
