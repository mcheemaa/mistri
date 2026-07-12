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
    secret = Integration.marker
    release = Queue.new
    released = false
    child = nil
    cleanup_attempted = false
    store = Mistri::Stores::Memory.new
    oracle = oracle_tool(secret)
    tools = Mistri::SubAgent.pack(provider: Mistri.provider(model), tools: [oracle],
                                  dispatcher: Mistri::Dispatchers::Thread.new,
                                  runtime_factory: runtime_factory(secret, release))
    parent = Mistri::Agent.new(
      provider: Mistri.provider(model), tools: tools,
      session: Mistri::Session.new(store:),
      system: "Delegate lookups to workers. When told to background one, do not " \
              "wait for it before answering; collect reports with read_agent."
    )

    begin
      first = parent.run(
        "Spawn a background worker named Beagle (instructions: call the oracle " \
        "tool and report its exact SECRET_VALUE) with the task of fetching the " \
        "secret value. Then, without waiting for Beagle, reply with exactly: " \
        "receipt acknowledged."
      )

      assert_predicate first, :completed?
      assert Integration.saw?(first.text, "receipt acknowledged"),
             "the parent must answer while the worker runs: #{first.text}"

      child = parent.session.children.first

      refute_nil child, "the background worker was never linked"
      refute_predicate child, :finished?, "the worker did not remain in the background"

      reports = []
      second = parent.run(
        "Now read Beagle with read_agent using wait true, and tell me its exact " \
        "SECRET_VALUE in one sentence."
      ) do |event|
        if event.type == :tool_started && event.tool_call.name == "read_agent"
          release << true
          released = true
        elsif event.type == :tool_result && event.tool_call.name == "read_agent"
          reports << event.message.text
        end
      end

      assert_predicate second, :completed?
      assert(reports.any? { |report| Integration.carried?(report, secret) },
             "read_agent never returned the report: #{reports.inspect}")

      reopened = Mistri::Session.new(store:, id: parent.session.id).children.first

      assert_equal "Beagle", reopened.name
      assert_equal :done, reopened.status, "the terminal did not survive a fresh session read"
      cleanup_attempted = true

      assert drain_worker(child), "the background worker did not release its lease"
    ensure
      release << true unless released
      drain_worker(child) if child && !cleanup_attempted
    end
  end

  # The report arrives on its own: no read_agent, no waiting. The worker
  # finishes, its report folds into the parent's context, and the model
  # answers from it.
  Integration.scenario(self, :a_workers_report_arrives_without_being_asked_for) do |model|
    Mistri.locks = Mistri::Locks::Memory.new
    secret = Integration.marker
    release = Queue.new
    released = false
    child = nil
    cleanup_attempted = false
    store = Mistri::Stores::Memory.new
    oracle = oracle_tool(secret)
    tools = Mistri::SubAgent.pack(provider: Mistri.provider(model), tools: [oracle],
                                  dispatcher: Mistri::Dispatchers::Thread.new,
                                  runtime_factory: runtime_factory(secret, release))
    parent = Mistri::Agent.new(
      provider: Mistri.provider(model), tools: tools,
      session: Mistri::Session.new(store:),
      system: "Delegate lookups to workers; their reports arrive on their own " \
              "when they finish."
    )

    begin
      first = parent.run(
        "Spawn a background worker named Terrier (instructions: call the oracle " \
        "tool and report its exact SECRET_VALUE) to fetch the secret value. Then, " \
        "without waiting for Terrier, reply with exactly: receipt acknowledged."
      )

      assert_predicate first, :completed?
      assert Integration.saw?(first.text, "receipt acknowledged"),
             "the parent must answer while the worker runs: #{first.text}"

      child = parent.session.children.first

      refute_nil child, "the background worker was never linked"
      refute_predicate child, :finished?, "the worker did not remain in the background"

      release << true
      released = true
      report = wait_for_report(parent.session)

      assert Integration.carried?(report["report"], secret),
             "the durable report lost the secret: #{report.inspect}"

      session = Mistri::Session.new(store:, id: parent.session.id)
      reader = Mistri::Agent.new(
        provider: Mistri.provider(model), tools: [], session:,
        system: "A worker report appears in context before the current request. " \
                "Return its exact SECRET_VALUE when asked."
      )
      second = reader.run("What exact SECRET_VALUE did Terrier report? Answer with only it.")

      assert_predicate second, :completed?
      assert Integration.carried?(second.text, secret),
             "the folded report never reached the model: #{second.text}"
      assert session.entries.any? { |entry| entry["report_id"] == report["id"] },
             "the durable report was never folded into the conversation"
      assert_equal :done, session.children.first.status
      cleanup_attempted = true

      assert drain_worker(child), "the background worker did not release its lease"
    ensure
      release << true unless released
      drain_worker(child) if child && !cleanup_attempted
    end
  end

  private

  def oracle_tool(secret, release = nil)
    Mistri::Tool.define("oracle", "Returns the exact SECRET_VALUE.") do
      release&.pop
      "SECRET_VALUE=#{secret}"
    end
  end

  def runtime_factory(secret, release)
    lambda do |spec|
      provider = Mistri.provider(spec.fetch("model"))
      Mistri::SubAgent::Runtime.new(
        provider:, system: spec.fetch("instructions"),
        tools: [oracle_tool(secret, release)], cleanup: -> { provider.close }
      )
    end
  end

  def wait_for_report(session)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    loop do
      report = session.entries.find { |entry| entry["type"] == "subagent_report" }
      return report if report

      flunk "the background report did not arrive" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def drain_worker(child)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    loop do
      held = Mistri.locks&.held?(Mistri::Child.lease_key(child.session_id))
      return true if child.finished? && !held
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end
end
