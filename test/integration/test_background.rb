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
    # Slow enough that the parent's receipt turn reliably finishes first;
    # a faster oracle folds its report mid-run and the parent, correctly,
    # answers with the number instead of the scripted acknowledgement.
    oracle = Mistri::Tool.define("oracle", "Answers the secret number, slowly.") do
      sleep 8
      number.to_s
    end
    runtime_factory = lambda do |spec|
      runtime_oracle = Mistri::Tool.define("oracle", "Answers the secret number, slowly.") do
        sleep 8
        number.to_s
      end
      provider = Mistri.provider(spec.fetch("model"))
      Mistri::SubAgent::Runtime.new(provider: provider,
                                    system: spec.fetch("instructions"),
                                    tools: [runtime_oracle], cleanup: -> { provider.close })
    end
    tools = Mistri::SubAgent.pack(provider: Mistri.provider(model), tools: [oracle],
                                  dispatcher: Mistri::Dispatchers::Thread.new,
                                  runtime_factory: runtime_factory)
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

  # The report arrives on its own: no read_agent, no waiting. The worker
  # finishes, its report folds into the parent's context, and the model
  # answers from it.
  Integration.scenario(self, :a_workers_report_arrives_without_being_asked_for) do |model|
    Mistri.locks = Mistri::Locks::Memory.new
    number = rand(100..900)
    store = Mistri::Stores::Memory.new
    oracle = Mistri::Tool.define("oracle", "Answers the secret number, slowly.") do
      sleep 1
      number.to_s
    end
    runtime_factory = lambda do |spec|
      runtime_oracle = Mistri::Tool.define("oracle", "Answers the secret number, slowly.") do
        sleep 1
        number.to_s
      end
      provider = Mistri.provider(spec.fetch("model"))
      Mistri::SubAgent::Runtime.new(provider: provider,
                                    system: spec.fetch("instructions"),
                                    tools: [runtime_oracle], cleanup: -> { provider.close })
    end
    tools = Mistri::SubAgent.pack(provider: Mistri.provider(model), tools: [oracle],
                                  dispatcher: Mistri::Dispatchers::Thread.new,
                                  runtime_factory: runtime_factory)
    parent = Mistri::Agent.new(
      provider: Mistri.provider(model), tools: tools,
      session: Mistri::Session.new(store:),
      system: "Delegate lookups to workers; their reports arrive on their own " \
              "when they finish."
    )

    first = parent.run(
      "Spawn a background worker named Terrier (instructions: call the oracle " \
      "tool and report its answer) to fetch the secret number. Then, without " \
      "waiting for Terrier, reply with exactly: receipt acknowledged."
    )

    assert_predicate first, :completed?

    # The typed entry lands in the parent session whether the report folded
    # mid-run or still waits in the inbox, so this await is race-free.
    ends = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    until parent.session.entries.any? { |entry| entry["type"] == "subagent_report" } ||
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > ends
      sleep 0.2
    end

    assert_predicate parent.session.children.first, :finished?

    second = parent.run("What number did your worker report? Answer with just the number.")

    assert_predicate second, :completed?
    assert Integration.saw?(second.text, number.to_s),
           "the folded report never reached the model: #{second.text}"
  end
end
