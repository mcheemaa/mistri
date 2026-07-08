# frozen_string_literal: true

require_relative "../support/integration"

# Background mode driven by a real model: spawn a worker in the background,
# acknowledge the receipt without waiting, then collect its report through
# the console.
class TestBackgroundIntegration < Minitest::Test
  def teardown
    Mistri.locks = nil
  end

  Integration.scenario(self, :model_backgrounds_a_worker_and_collects_its_report) do |model|
    Mistri.locks = Mistri::Locks::Memory.new
    number = rand(100..900)
    store = Mistri::Stores::Memory.new
    oracle = Mistri::Tool.define("oracle", "Answers the secret number, slowly.") do
      sleep 2
      number.to_s
    end
    tools = Mistri::SubAgent.pack(provider: Mistri.provider(model), tools: [oracle],
                                  dispatcher: Mistri::Dispatchers::Thread.new)
    parent = Mistri::Agent.new(
      provider: Mistri.provider(model), tools: tools,
      session: Mistri::Session.new(store:),
      system: "Delegate lookups to workers. When told to background one, do not " \
              "wait for it before answering; collect reports with read_agent."
    )

    first = parent.run(
      "Spawn a background worker named Beagle (instructions: call the oracle " \
      "tool and report its answer) with the task of fetching the secret " \
      "number. Then, without waiting for Beagle, reply with exactly: receipt " \
      "acknowledged."
    )

    assert_predicate first, :completed?
    assert Integration.saw?(first.text, "receipt acknowledged"),
           "the parent must answer while the worker runs: #{first.text}"

    second = parent.run(
      "Now read Beagle with read_agent using wait true, and tell me the " \
      "secret number in one sentence."
    )

    assert_predicate second, :completed?
    assert Integration.saw?(second.text, number.to_s),
           "the report never surfaced: #{second.text}"

    child = parent.session.children.first

    assert_equal "Beagle", child.name
    assert_equal :done, child.status
    assert_equal :done, child.status, "terminal entry persists"
  end
end
