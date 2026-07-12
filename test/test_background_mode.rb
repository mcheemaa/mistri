# frozen_string_literal: true

require_relative "test_helper"

# Background mode: dispatch is a seam, receipts are truthful, lifecycle is
# entries, and a background child's life belongs to the console, not to the
# parent's already-finished turn.
class TestBackgroundMode < Minitest::Test
  def teardown
    Mistri.locks = nil
  end

  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def runtime_factory(provider, tools: [], system: nil)
    lambda do |spec|
      Mistri::SubAgent::Runtime.new(provider: provider, system: system || spec["instructions"],
                                    tools: tools)
    end
  end

  def spawn_call(arguments)
    fake({ tool_calls: [{ name: "spawn_agent", arguments: arguments }] },
         { text: "Parent moved on." })
  end

  def drop_dispatcher
    Class.new do
      attr_reader :spec

      def call(spec, _runner)
        @spec = spec
        nil
      end
    end.new
  end

  def await_status(child, wanted, deadline: 3)
    ends = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
    while child.status != wanted && Process.clock_gettime(Process::CLOCK_MONOTONIC) < ends
      sleep 0.05
    end
    child.status
  end

  def test_a_dispatcher_requires_a_runtime_factory
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake, dispatcher: Mistri::Dispatchers::Inline.new)
    end

    assert_match(/runtime_factory/, error.message)

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake, dispatcher: Object.new,
                               runtime_factory: ->(_spec) {})
    end

    assert_match(/dispatcher must be callable/, error.message)
  end

  def test_inline_dispatcher_finishes_during_the_spawn_and_says_so
    child_fake = fake({ text: "The answer is 7." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake,
                                     dispatcher: Mistri::Dispatchers::Inline.new,
                                     runtime_factory: runtime_factory(child_fake))
    parent = spawn_call({ "name" => "Corgi", "task" => "answer", "instructions" => "Answer.",
                          "mode" => "background" })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    result = Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")

    assert_equal "Parent moved on.", result.text
    receipt = session.messages.select(&:tool?).last

    assert_match(/already finished \(done\)/, receipt.text)
    assert_equal "background", receipt.ui["mode"]
    child = session.children.first

    assert_equal :done, child.status
    assert_equal "The answer is 7.", child.report

    # The child finished during the spawn itself, so its report folded at
    # the very next turn boundary: the parent's final word already saw it.
    assert_includes parent.requests.last[:messages].map(&:text).join("\n"),
                    "[Corgi finished] The answer is 7."
  end

  def test_thread_dispatcher_runs_the_child_while_the_parent_moves_on
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    slow = Mistri::Tool.define("slow", "Takes a while.") do
      sleep 0.6
      "worked"
    end
    child_fake = fake({ tool_calls: [{ name: "slow", arguments: {} }] },
                      { text: "Finished the slow work." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [slow],
                                     dispatcher: Mistri::Dispatchers::Thread.new,
                                     runtime_factory: runtime_factory(child_fake, tools: [slow]))
    parent = spawn_call({ "name" => "Whippet", "task" => "work slowly",
                          "instructions" => "Use slow, then report.",
                          "mode" => "background" })
    session = Mistri::Session.new(store:)

    result = Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")

    assert_equal "Parent moved on.", result.text, "the parent never waits"
    child = session.children.first
    receipt = session.messages.select(&:tool?).last

    assert_match(/working in the background/, receipt.text)
    assert_includes Mistri::Child::LIVE, child.status,
                    "the child has not finished as the parent moves on"

    assert_equal :done, await_status(child, :done)
    assert_equal "Finished the slow work.", child.report
    refute Mistri.locks.held?(Mistri::Child.lease_key(child.session_id))

    # The parent's run was long over, so the report waits in its inbox.
    ends = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.05 while session.pending_inbox.empty? &&
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) < ends

    assert_equal "Finished the slow work.", session.pending_inbox.first["report"]
  end

  def test_a_dropped_spec_reads_queued_and_run_dispatched_picks_it_up
    dropper = drop_dispatcher
    child_fake = fake({ text: "Ran from the job." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, dispatcher: dropper,
                                     runtime_factory: runtime_factory(child_fake))
    parent = spawn_call({ "name" => "Basset", "task" => "do the thing",
                          "instructions" => "You do things.", "mode" => "background" })
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)

    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")

    child = session.children.first

    assert_equal :queued, child.status, "dispatched but never started is queued, honestly"

    # The host job reconstructs from the wire-shaped spec and calls back in.
    spec = JSON.parse(JSON.generate(dropper.spec))
    result = Mistri::SubAgent.run_dispatched(spec, provider: child_fake,
                                                   system: spec.fetch("instructions"),
                                                   tools: [], store: store)

    assert_predicate result, :completed?
    assert_equal :done, child.status
    assert_equal "Ran from the job.", child.report
  end

  def test_stopping_a_background_child_needs_no_parent
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    slow = Mistri::Tool.define("slow", "Takes a while.") do
      sleep 1.4
      "worked"
    end
    child_fake = fake({ tool_calls: [{ name: "slow", arguments: {} }] },
                      { text: "never reached" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [slow],
                                     dispatcher: Mistri::Dispatchers::Thread.new,
                                     runtime_factory: runtime_factory(child_fake, tools: [slow]))
    parent = spawn_call({ "name" => "Pointer", "task" => "work",
                          "instructions" => "Use slow.", "mode" => "background" })
    session = Mistri::Session.new(store:)

    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")
    child = session.children.first

    assert child.stop, "the console can stop a background child"
    assert_equal :stopped, await_status(child, :stopped)
  end

  def test_the_console_treats_a_queued_worker_as_live
    dropper = drop_dispatcher
    child_fake = fake
    spawn = Mistri::SubAgent.spawner(provider: child_fake, dispatcher: dropper,
                                     runtime_factory: runtime_factory(child_fake))
    parent = spawn_call({ "name" => "Collie", "task" => "t", "instructions" => "You help.",
                          "mode" => "background" })
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")
    context = Mistri::ToolContext.new(session: session, signal: nil, emit: nil, app: nil)

    waited = Mistri::Console.read_agent(timeout: 0.15, poll: 0.05)
                            .call({ "agent" => "Collie", "wait" => true }, context)

    assert_match(/still queued/, waited, "a queued worker is worth waiting on")

    steered = Mistri::Console.steer_agent.call(
      { "agent" => "Collie", "message" => "prioritize speed" }, context
    )

    assert_match(/Queued\./, steered)
    child_session = Mistri::Session.new(store:, id: session.children.first.session_id)

    assert_equal 1, child_session.pending_steers.length,
                 "a steer waits in the log for the job to start"
  end

  def test_stopping_a_queued_worker_cancels_it_for_good
    Mistri.locks = Mistri::Locks::Memory.new
    dropper = drop_dispatcher
    child_fake = fake({ text: "should never run" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, dispatcher: dropper,
                                     runtime_factory: runtime_factory(child_fake))
    parent = spawn_call({ "name" => "Saluki", "task" => "t", "instructions" => "You help.",
                          "mode" => "background" })
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")
    child = session.children.first
    context = Mistri::ToolContext.new(session: session, signal: nil, emit: nil, app: nil)

    cancelled = Mistri::Console.stop_agent.call({ "agent" => "Saluki" }, context)

    assert_match(/Cancelled\. Saluki is marked stopped; ordinary queue delivery/, cancelled)
    assert_equal :stopped, child.status

    # The queue delivers late anyway; the runner honors the terminal.
    result = Mistri::SubAgent.run_dispatched(dropper.spec, provider: child_fake,
                                                           system: "You help.", tools: [],
                                                           store: store)

    assert_nil result
    assert_equal :stopped, child.status
    entries = Mistri::Session.new(store:, id: child.session_id).entries

    assert(entries.none? { |entry| entry["type"] == Mistri::Child::STARTED },
           "a cancelled child never starts")
  end

  def test_a_dispatched_child_that_needs_approval_leaves_no_open_requests
    risky = Mistri::Tool.define("risky", "Needs a human sometimes.",
                                needs_approval: ->(args) { args["danger"] == true },
                                schema: -> { boolean :danger, "Whether it is dangerous" }) do
      "did it"
    end
    child_fake = fake({ tool_calls: [{ name: "risky", arguments: { "danger" => true } }] })
    dropper = drop_dispatcher
    spawn = Mistri::SubAgent.spawner(
      provider: child_fake, tools: [risky], dispatcher: dropper,
      runtime_factory: runtime_factory(child_fake, tools: [risky])
    )
    parent = spawn_call({ "name" => "Akita", "task" => "do the risky thing",
                          "instructions" => "Use risky.", "mode" => "background" })
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")

    Mistri::SubAgent.run_dispatched(dropper.spec, provider: child_fake,
                                                  system: "Use risky.", tools: [risky],
                                                  store: store)

    child = session.children.first
    child_session = Mistri::Session.new(store:, id: child.session_id)

    assert_equal :failed, child.status
    assert_empty child_session.open_approvals,
                 "no approval request may stay open on a finished child"
  end

  def test_only_mode_is_added_to_the_schema_by_a_dispatcher
    bare = Mistri::SubAgent.spawner(provider: fake)
    child_fake = fake
    dispatched = Mistri::SubAgent.spawner(
      provider: child_fake, dispatcher: Mistri::Dispatchers::Inline.new,
      runtime_factory: runtime_factory(child_fake)
    )

    refute bare.input_schema["properties"].key?("mode")
    assert dispatched.input_schema["properties"].key?("mode")
    refute dispatched.input_schema["properties"].key?("workspace")
  end
end
