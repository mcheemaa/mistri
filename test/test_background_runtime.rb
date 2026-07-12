# frozen_string_literal: true

require_relative "test_helper"

# Background runtimes turn a durable capability grant into fresh host-owned
# objects, then fail closed if the reconstructed model or tools drift.
class TestBackgroundRuntime < Minitest::Test # rubocop:disable Metrics/ClassLength -- adversarial dispatch invariants share one fixture
  def teardown
    Mistri.locks = nil
  end

  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def spawn_call(arguments)
    fake({ tool_calls: [{ name: "spawn_agent", arguments: arguments }] },
         { text: "Parent moved on." })
  end

  def drop_dispatcher
    Class.new do
      attr_reader :spec

      def call(spec, _runner)
        @spec = spec
      end
    end.new
  end

  def queue(tools: [], selected: nil, store: nil)
    dispatcher = drop_dispatcher
    catalog_provider = fake
    runtime_factory = ->(_spec) { raise "a queue dispatcher must not invoke the local runner" }
    spawn = Mistri::SubAgent.spawner(provider: catalog_provider, tools: tools,
                                     dispatcher: dispatcher, runtime_factory: runtime_factory)
    arguments = { "name" => "Basset", "task" => "work",
                  "instructions" => "Do the work.", "mode" => "background" }
    arguments["tools"] = selected unless selected.nil?
    store ||= Mistri::Stores::Memory.new
    session = Mistri::Session.new(store: store)

    Mistri::Agent.new(provider: spawn_call(arguments), tools: [spawn], session: session).run("go")
    [dispatcher.spec, store, session]
  end

  def await_status(child, wanted, deadline: 3)
    ends = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
    while child.status != wanted && Process.clock_gettime(Process::CLOCK_MONOTONIC) < ends
      sleep 0.05
    end
    child.status
  end

  def blocking_started_store
    Class.new do
      attr_reader :entered, :continue

      def initialize
        @store = Mistri::Stores::Memory.new
        @entered = Queue.new
        @continue = Queue.new
        @block_started = false
      end

      def block_started! = @block_started = true

      def append(id, entry)
        if @block_started && entry["type"] == Mistri::Child::STARTED
          @block_started = false
          @entered << true
          @continue.pop
        end
        @store.append(id, entry)
      end

      def load(id) = @store.load(id)
    end.new
  end

  def blocking_terminal_store
    Class.new do
      attr_reader :entered, :continue

      def initialize
        @store = Mistri::Stores::Memory.new
        @entered = Queue.new
        @continue = Queue.new
        @block_terminal = false
      end

      def block_terminal! = @block_terminal = true

      def append(id, entry)
        if @block_terminal && entry["type"] == Mistri::Child::TERMINAL
          @block_terminal = false
          @entered << true
          @continue.pop
        end
        @store.append(id, entry)
      end

      def load(id) = @store.load(id)
    end.new
  end

  def report_observing_store
    Class.new do
      attr_accessor :lease_key
      attr_reader :report_lease_states

      def initialize
        @store = Mistri::Stores::Memory.new
        @report_lease_states = []
      end

      def append(id, entry)
        @report_lease_states << Mistri.locks&.held?(lease_key) if entry["type"] == "subagent_report"
        @store.append(id, entry)
      end

      def load(id) = @store.load(id)
    end.new
  end

  def fail_once_report_store
    Class.new do
      def initialize
        @store = Mistri::Stores::Memory.new
        @fail_report = true
      end

      def append(id, entry)
        if @fail_report && entry["type"] == "subagent_report"
          @fail_report = false
          raise "parent report unavailable"
        end
        @store.append(id, entry)
      end

      def load(id) = @store.load(id)
    end.new
  end

  def valid_spec
    { "spec_version" => Mistri::SubAgent::DISPATCH_SPEC_VERSION,
      "name" => "Raw", "session_id" => SecureRandom.uuid, "parent_session_id" => nil,
      "type" => "general-purpose", "instructions" => "Do the work.",
      "task" => "work", "tool_names" => [], "model" => "fake-1" }
  end

  def test_thread_factory_builds_an_isolated_workspace_inside_the_worker
    Mistri.locks = Mistri::Locks::Memory.new
    parent_workspace = Mistri::Workspace::Memory.new
    parent_workspace.write("notes.txt", "parent")
    declared_write = Mistri::Tools.write_file(parent_workspace)
    factory_thread = nil
    child_workspace = nil
    runtime_factory = lambda do |spec|
      factory_thread = Thread.current
      child_workspace = Mistri::Workspace::Memory.new
      provider = fake(
        { tool_calls: [{ name: "write_file",
                         arguments: { "path" => "notes.txt", "content" => "child" } }] },
        { text: "Wrote the child file." }
      )
      Mistri::SubAgent::Runtime.new(
        provider: provider, system: spec.fetch("instructions"),
        tools: [Mistri::Tools.write_file(child_workspace)]
      )
    end
    spawn = Mistri::SubAgent.spawner(
      provider: fake, tools: [declared_write], dispatcher: Mistri::Dispatchers::Thread.new,
      runtime_factory: runtime_factory
    )
    parent = spawn_call({ "name" => "Corgi", "task" => "write the child file",
                          "instructions" => "Use write_file.", "mode" => "background" })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    Mistri::Agent.new(provider: parent, tools: [spawn], session: session).run("go")

    assert_equal :done, await_status(session.children.first, :done)
    refute_equal Thread.current, factory_thread, "construction belongs to the worker thread"
    assert_equal "parent", parent_workspace.read("notes.txt")
    assert_equal "child", child_workspace.read("notes.txt")
  end

  def test_new_specs_are_versioned_immutable_json_without_workspace_claims
    spec, = queue

    assert_equal Mistri::SubAgent::DISPATCH_SPEC_VERSION, spec["spec_version"]
    refute spec.key?("workspace")
    assert_predicate spec, :frozen?
    assert_predicate spec.fetch("tool_names"), :frozen?
    assert_equal spec, JSON.parse(JSON.generate(spec))
  end

  def test_a_selected_background_model_is_only_constructed_by_the_worker
    dispatcher = drop_dispatcher
    runtime_factory = ->(_spec) { raise "the queue owns execution" }
    spawn = Mistri::SubAgent.spawner(provider: fake, models: ["host-worker-v1"],
                                     dispatcher: dispatcher,
                                     runtime_factory: runtime_factory)
    parent = spawn_call({ "name" => "Corgi", "task" => "work",
                          "instructions" => "Do the work.", "mode" => "background",
                          "model" => "host-worker-v1" })

    Mistri::Agent.new(provider: parent, tools: [spawn]).run("go")

    assert_equal "host-worker-v1", dispatcher.spec["model"]
  end

  def test_a_background_default_requires_a_stable_model_identity_before_dispatch
    catalog = Class.new do
      def stream(**) = raise("the catalog provider must not run")
    end.new
    dispatcher = drop_dispatcher
    spawn = Mistri::SubAgent.spawner(
      provider: catalog, dispatcher: dispatcher,
      runtime_factory: ->(_spec) { raise "the queue owns execution" }
    )
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    result = Mistri::Agent.new(
      provider: spawn_call({ "name" => "Corgi", "task" => "work",
                             "instructions" => "Work.", "mode" => "background" }),
      tools: [spawn], session: session
    ).run("go")

    assert_predicate result, :completed?
    assert_nil dispatcher.spec
    assert_empty session.children
    tool_result = session.messages.find(&:tool?)

    assert_predicate tool_result, :tool_error?
    assert_match(/non-empty model identity/, tool_result.text)
  end

  def test_background_spec_rejects_a_non_json_parent_identity_before_dispatch
    dispatcher = drop_dispatcher
    spawn = Mistri::SubAgent.spawner(
      provider: fake, dispatcher: dispatcher,
      runtime_factory: ->(_spec) { raise "the queue owns execution" }
    )
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new, id: Object.new)
    parent = spawn_call({ "name" => "Corgi", "task" => "work",
                          "instructions" => "Work.", "mode" => "background" })

    result = Mistri::Agent.new(provider: parent, tools: [spawn], session: session).run("go")

    assert_predicate result, :completed?
    assert_nil dispatcher.spec
    assert_empty session.children
    tool_result = session.messages.find(&:tool?)

    assert_predicate tool_result, :tool_error?
    assert_match(/background child spec is not bounded JSON/, tool_result.text)
  end

  def test_an_extra_runtime_tool_fails_before_provider_or_handler_execution
    spec, store, session = queue(selected: [])
    called = false
    danger = Mistri::Tool.define("danger", "Should not run.") do
      called = true
      "ran"
    end
    provider = fake({ tool_calls: [{ name: "danger", arguments: {} }] })
    factory = lambda do |_owned_spec|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.", tools: [danger])
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    end

    assert_match(/extra: danger/, error.message)
    refute called
    assert_empty provider.requests
    assert_equal :failed, session.children.first.status
    assert_equal "failed", session.pending_inbox.first["status"]
  end

  def test_a_missing_runtime_tool_fails_closed
    alpha = Mistri::Tool.define("alpha", "Alpha.") { "a" }
    beta = Mistri::Tool.define("beta", "Beta.") { "b" }
    spec, store, = queue(tools: [alpha, beta])
    provider = fake({ text: "never" })
    runtime_factory = lambda do |_owned_spec|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.", tools: [alpha])
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: runtime_factory)
    end

    assert_match(/missing: beta/, error.message)
    assert_empty provider.requests
  end

  def test_runtime_tools_are_reordered_to_the_durable_grant
    alpha = Mistri::Tool.define("alpha", "Alpha.") { "a" }
    beta = Mistri::Tool.define("beta", "Beta.") { "b" }
    spec, store, = queue(tools: [alpha, beta])
    provider = fake({ text: "done" })
    runtime_factory = lambda do |_owned_spec|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.",
                                    tools: [beta, alpha])
    end

    Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: runtime_factory)

    names = provider.requests.first[:options][:tools].map { |tool| tool.fetch(:name) }

    assert_equal %w[alpha beta], names
  end

  def test_runtime_model_must_match_the_durable_grant
    spec, store, = queue
    wrong_model = Class.new do
      def model = "other-model"
      def stream(**) = raise("must not run")
    end.new
    runtime_factory = lambda do |_owned_spec|
      Mistri::SubAgent::Runtime.new(provider: wrong_model, system: "Do the work.")
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: runtime_factory)
    end

    assert_match(/does not match the granted model/, error.message)
  end

  def test_factory_shape_errors_fail_and_report_the_child
    spec, store, session = queue

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store,
                                            runtime_factory: ->(_owned_spec) { {} })
    end

    assert_match(/must return Mistri::SubAgent::Runtime/, error.message)
    assert_equal :failed, session.children.first.status
    assert_equal "failed", session.pending_inbox.first["status"]
  end

  def test_malformed_dispatch_specs_never_reach_the_factory
    factory_calls = 0
    factory = lambda do |_spec|
      factory_calls += 1
      raise "must not construct"
    end
    cases = [
      ["not an object", /bounded JSON object/],
      [valid_spec.merge("name" => ""), /non-empty name/],
      [valid_spec.merge("task" => ""), /non-empty task/],
      [valid_spec.merge("model" => nil), /model must be a non-empty string/],
      [valid_spec.merge("model" => 7), /model must be a non-empty string/],
      [valid_spec.merge("type" => ""), /type must be a non-empty string/],
      [valid_spec.merge("parent_session_id" => 7), /parent_session_id must be a string or null/],
      [valid_spec.merge("instructions" => 7), /instructions must be a string or null/],
      [valid_spec.merge("tool_names" => [nil]), /tool_names must be non-empty strings/],
      [valid_spec.merge("tool_names" => %w[same same]), /duplicate tool names/]
    ]

    cases.each do |spec, message|
      store = Mistri::Stores::Memory.new
      if spec.is_a?(Hash) && spec["session_id"].is_a?(String)
        Mistri::Session.new(store: store, id: spec.fetch("session_id"))
                       .append(Mistri::Child::DISPATCHED, "spec" => spec)
      end
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::SubAgent.run_dispatched(spec, store: store,
                                              runtime_factory: factory)
      end
      assert_match message, error.message
    end

    assert_equal 0, factory_calls
  end

  def test_a_versioned_delivery_requires_its_persisted_grant
    spec = valid_spec
    store = Mistri::Stores::Memory.new
    child = Mistri::Session.new(store: store, id: spec.fetch("session_id"))
    child.append(Mistri::Child::DISPATCHED, {})

    error = assert_raises(Mistri::DispatchGrantError) do
      Mistri::SubAgent.run_dispatched(
        spec, provider: fake({ text: "never" }), system: "Do the work.", tools: [], store: store
      )
    end

    assert_match(/missing its durable dispatch grant/, error.message)
    assert_equal :queued,
                 Mistri::Child.new(name: spec.fetch("name"), session_id: child.id,
                                   store: store).status
    assert(child.entries.none? { |entry| entry["type"] == Mistri::Child::TERMINAL })
  end

  def test_queue_payload_cannot_widen_the_persisted_tool_grant
    spec, store, session = queue(selected: [])
    tampered = JSON.parse(JSON.generate(spec))
    tampered["tool_names"] = ["danger"]
    called = false
    danger = Mistri::Tool.define("danger", "Must not run.") do
      called = true
      "ran"
    end
    provider = fake({ tool_calls: [{ name: "danger", arguments: {} }] })
    runtime_factory = lambda do |_owned_spec|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.", tools: [danger])
    end

    error = assert_raises(Mistri::DispatchGrantError) do
      Mistri::SubAgent.run_dispatched(tampered, store: store,
                                                runtime_factory: runtime_factory)
    end

    assert_match(/does not match the durable dispatch grant/, error.message)
    refute called
    assert_empty provider.requests
    assert_equal :queued, session.children.first.status
    assert_empty session.pending_inbox
  end

  def test_tampered_finished_payload_cannot_reroute_a_report
    spec, store, session = queue
    Mistri::SubAgent.run_dispatched(spec, provider: fake({ text: "done" }),
                                          system: "Do the work.", tools: [], store: store)
    victim = Mistri::Session.new(store: store)
    tampered = JSON.parse(JSON.generate(spec))
    tampered["name"] = "Impostor"
    tampered["parent_session_id"] = victim.id

    assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(tampered, provider: fake({ text: "never" }),
                                                system: "Do the work.", tools: [], store: store)
    end

    assert_empty victim.pending_inbox
    assert_equal 1, session.pending_inbox.length
  end

  def test_unknown_versioned_fields_never_reach_the_factory
    spec = valid_spec.merge("tenant_id" => "injected")
    store = Mistri::Stores::Memory.new
    child = Mistri::Session.new(store: store, id: spec.fetch("session_id"))
    child.append(Mistri::Child::DISPATCHED, "spec" => spec)
    calls = 0
    factory = lambda do |_owned_spec|
      calls += 1
      Mistri::SubAgent::Runtime.new(provider: fake({ text: "never" }))
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    end

    assert_match(/unknown fields: tenant_id/, error.message)
    assert_equal 0, calls
  end

  def test_invalid_runtime_inputs_fail_before_execution
    alpha = Mistri::Tool.define("alpha", "Alpha.") { "a" }
    cases = [
      [->(spec, store) { Mistri::SubAgent.run_dispatched(spec, store: store) },
       Mistri::ConfigurationError, /needs runtime_factory or provider/, []],
      [lambda do |spec, store|
         Mistri::SubAgent.run_dispatched(spec, store: store,
                                               runtime_factory: Object.new)
       end,
       Mistri::ConfigurationError, /runtime_factory must be callable/, []],
      [lambda do |spec, store|
         factory = ->(_owned) { Mistri::SubAgent::Runtime.new(provider: fake) }
         Mistri::SubAgent.run_dispatched(spec, store: store, provider: fake,
                                               runtime_factory: factory)
       end,
       ArgumentError, /choose runtime_factory or direct runtime fields/, []],
      [lambda do |spec, store|
         Mistri::SubAgent.run_dispatched(spec, store: store,
                                               provider: Object.new, tools: [])
       end,
       Mistri::ConfigurationError, /provider must respond to stream/, []],
      [lambda do |spec, store|
         runtime = ->(_owned) { Mistri::SubAgent::Runtime.new(provider: fake, tools: [Object.new]) }
         Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: runtime)
       end,
       Mistri::ConfigurationError, /tools must be Mistri::Tool instances/, []],
      [lambda do |spec, store|
         runtime = lambda do |_owned|
           Mistri::SubAgent::Runtime.new(provider: fake, tools: [alpha, alpha])
         end
         Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: runtime)
       end,
       Mistri::ConfigurationError, /duplicate tool names/, [alpha]]
    ]

    cases.each do |run, error_class, message, declared|
      spec, store, = queue(tools: declared)
      error = assert_raises(error_class) { run.call(spec, store) }
      assert_match message, error.message
    end
  end

  def test_runtime_and_spawner_reject_inert_host_configuration
    error = assert_raises(ArgumentError) do
      Mistri::SubAgent::Runtime.new(provider: fake, tools: "alpha")
    end
    assert_match(/tools must be an Array/, error.message)

    error = assert_raises(ArgumentError) do
      Mistri::SubAgent::Runtime.new(provider: fake, cleanup: Object.new)
    end
    assert_match(/cleanup must be callable/, error.message)

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake, runtime_factory: ->(_spec) {})
    end
    assert_match(/requires a dispatcher/, error.message)
  end

  def test_runtime_skills_cannot_add_an_undeclared_reader_tool
    spec, store, = queue(selected: [])
    provider = fake({ tool_calls: [{ name: "read_skill", arguments: { "name" => "secret" } }] })
    skill = Mistri::Skill.new(name: "secret", description: "Secret.", body: "classified")
    factory = lambda do |_owned_spec|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.", skills: [skill])
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    end

    assert_match(/skills would add tools outside the durable grant/, error.message)
    assert_empty provider.requests
  end

  def test_runtime_options_cannot_replace_durable_lifecycle_keywords
    %i[session task signal emit lease child started label].each do |name|
      spec, store, session = queue
      other = Mistri::Session.new(store: store)
      provider = fake({ text: "must not run" })
      value = name == :session ? other : Object.new
      factory = lambda do |_owned_spec|
        Mistri::SubAgent::Runtime.new(provider: provider, **{ name => value })
      end

      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
      end

      assert_match(/unsupported sub-agent options:.*#{name}/, error.message)
      assert_empty provider.requests
      assert_empty other.entries
      assert_equal :failed, session.children.first.status
    end
  end

  def test_transient_factory_failures_remain_retryable
    Mistri.locks = Mistri::Locks::Memory.new
    spec, store, session = queue

    assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store,
                                            runtime_factory: lambda do |_owned|
                                              raise Mistri::ConfigurationError,
                                                    "registry unavailable"
                                            end)
    end

    child = session.children.first

    assert_equal :interrupted, child.status
    assert_empty session.pending_inbox
    child_entries = Mistri::Session.new(store: store, id: child.session_id).entries

    assert(child_entries.none? { |entry| entry["type"] == Mistri::Child::TERMINAL })

    provider = fake({ text: "recovered" })
    factory = lambda do |_owned|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.")
    end
    result = Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)

    assert_predicate result, :completed?
    assert_equal :done, child.status
  end

  def test_an_interrupted_factory_retry_can_be_cancelled_durably
    Mistri.locks = Mistri::Locks::Memory.new
    spec, store, session = queue
    assert_raises(RuntimeError) do
      Mistri::SubAgent.run_dispatched(
        spec, store: store, runtime_factory: ->(_owned) { raise "database down" }
      )
    end
    child = session.children.first

    assert_equal :interrupted, child.status
    context = Mistri::ToolContext.new(session: session, signal: nil, emit: nil, app: nil)
    output = Mistri::Console.stop_agent.call({ "agent" => child.session_id }, context)

    assert_match(/Cancelled.*marked stopped; ordinary queue delivery/, output)
    assert_equal :stopped, child.status
    assert_equal "stopped", session.pending_inbox.first["status"]
    provider = fake({ text: "must not run" })
    retried = Mistri::SubAgent.run_dispatched(
      spec, provider: provider, system: "Do the work.", tools: [], store: store
    )

    assert_nil retried
    assert_empty provider.requests
  end

  def test_in_process_factory_failures_end_the_child
    catalog = fake
    factory = ->(_owned) { raise "bad local configuration" }
    spawn = Mistri::SubAgent.spawner(provider: catalog,
                                     dispatcher: Mistri::Dispatchers::Inline.new,
                                     runtime_factory: factory)
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    Mistri::Agent.new(
      provider: spawn_call({ "name" => "Corgi", "task" => "work",
                             "instructions" => "Work.", "mode" => "background" }),
      tools: [spawn], session: session
    ).run("go")

    assert_equal :failed, session.children.first.status
    assert_match(/bad local configuration/, session.children.first.error)
  end

  def test_stop_during_factory_construction_never_reaches_the_provider
    Mistri.locks = Mistri::Locks::Memory.new
    spec, store, session = queue
    entered = Queue.new
    continue = Queue.new
    provider = fake({ text: "must not run" })
    factory = lambda do |_owned|
      entered << true
      continue.pop
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.")
    end
    result = nil
    thread = Thread.new do
      result = Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    end
    entered.pop

    assert session.children.first.stop
    continue << true
    thread.join

    assert_predicate result, :aborted?
    assert_empty provider.requests
    terminals = Mistri::Session.new(store: store, id: spec.fetch("session_id")).entries
                               .select { |entry| entry["type"] == Mistri::Child::TERMINAL }
    statuses = terminals.map { |entry| entry["status"] }

    assert_equal ["stopped"], statuses
  end

  def test_queued_stop_cannot_overtake_a_runner_that_holds_the_lease
    Mistri.locks = Mistri::Locks::Memory.new
    store = blocking_started_store
    dispatcher = drop_dispatcher
    provider = fake({ text: "must not run" })
    factory = lambda do |_owned|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.")
    end
    spawn = Mistri::SubAgent.spawner(provider: fake, dispatcher: dispatcher,
                                     runtime_factory: factory)
    session = Mistri::Session.new(store: store)
    parent = spawn_call({ "name" => "Corgi", "task" => "work",
                          "instructions" => "Work.", "mode" => "background" })
    Mistri::Agent.new(provider: parent, tools: [spawn], session: session).run("go")
    store.block_started!
    result = nil
    thread = Thread.new do
      result = Mistri::SubAgent.run_dispatched(dispatcher.spec, store: store,
                                                                runtime_factory: factory)
    end
    store.entered.pop

    assert session.children.first.stop
    store.continue << true
    thread.join

    assert_predicate result, :aborted?
    assert_empty provider.requests
    entries = Mistri::Session.new(store: store,
                                  id: dispatcher.spec.fetch("session_id")).entries
    terminals = entries.select { |entry| entry["type"] == Mistri::Child::TERMINAL }
    statuses = terminals.map { |entry| entry["status"] }

    assert_equal ["stopped"], statuses
  end

  def test_queued_stop_reports_when_the_only_delivery_loses_the_cancellation_lease
    Mistri.locks = Mistri::Locks::Memory.new
    store = blocking_terminal_store
    dispatcher = drop_dispatcher
    provider = fake({ text: "must not run" })
    factory = lambda do |_owned|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.")
    end
    spawn = Mistri::SubAgent.spawner(provider: fake, dispatcher: dispatcher,
                                     runtime_factory: factory)
    session = Mistri::Session.new(store: store)
    parent = spawn_call({ "name" => "Corgi", "task" => "work",
                          "instructions" => "Work.", "mode" => "background" })
    Mistri::Agent.new(provider: parent, tools: [spawn], session: session).run("go")
    store.block_terminal!
    stopped = nil
    stopper = Thread.new { stopped = session.children.first.stop }
    store.entered.pop

    delivery = Mistri::SubAgent.run_dispatched(dispatcher.spec, store: store,
                                                                runtime_factory: factory)
    store.continue << true
    stopper.join

    assert stopped
    assert_nil delivery
    assert_empty provider.requests
    assert_equal :stopped, session.children.first.status
    reports = session.pending_inbox

    assert_equal 1, reports.length
    assert_equal "stopped", reports.first["status"]
    assert_equal dispatcher.spec.fetch("session_id"), reports.first["session_id"]
  end

  def test_legacy_queued_stop_reports_when_its_only_delivery_loses_the_lease
    Mistri.locks = Mistri::Locks::Memory.new
    store = blocking_terminal_store
    parent = Mistri::Session.new(store: store)
    child = Mistri::Session.new(store: store)
    parent.append("subagent", "name" => "Legacy", "session_id" => child.id)
    child.append(Mistri::Child::DISPATCHED, {})
    spec = { "name" => "Legacy", "session_id" => child.id,
             "parent_session_id" => parent.id, "task" => "work",
             "tool_names" => [], "model" => nil }
    provider = fake({ text: "must not run" })
    store.block_terminal!
    stopped = nil
    stopper = Thread.new { stopped = parent.children.first.stop }
    store.entered.pop

    delivery = Mistri::SubAgent.run_dispatched(
      spec, provider: provider, system: "Do the work.", tools: [], store: store
    )
    store.continue << true
    stopper.join

    assert stopped
    assert_nil delivery
    assert_empty provider.requests
    assert_equal :stopped, parent.children.first.status
    reports = parent.pending_inbox

    assert_equal 1, reports.length
    assert_equal "stopped", reports.first["status"]
    assert_equal child.id, reports.first["session_id"]
  end

  def test_repeated_stop_heals_a_failed_parent_report_write
    Mistri.locks = Mistri::Locks::Memory.new
    store = fail_once_report_store
    _spec, _, session = queue(store: store)
    child = session.children.first

    error = assert_raises(RuntimeError) { child.stop }

    assert_match(/parent report unavailable/, error.message)
    assert_equal :stopped, child.status
    assert_empty session.pending_inbox
    context = Mistri::ToolContext.new(session: session, signal: nil, emit: nil, app: nil)

    output = Mistri::Console.stop_agent.call({ "agent" => child.session_id }, context)
    duplicate = Mistri::Console.stop_agent.call({ "agent" => child.session_id }, context)

    assert_match(/already stopped/, output)
    assert_match(/already stopped/, duplicate)
    assert_equal 1, session.pending_inbox.length
    assert_equal "stopped", session.pending_inbox.first["status"]
  end

  def test_a_stop_is_not_lost_when_the_factory_raises
    Mistri.locks = Mistri::Locks::Memory.new
    spec, store, session = queue
    entered = Queue.new
    continue = Queue.new
    error = nil
    factory = lambda do |_owned|
      entered << true
      continue.pop
      raise "database down"
    end
    thread = Thread.new do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    rescue StandardError => e
      error = e
    end
    entered.pop

    assert session.children.first.stop
    continue << true
    thread.join

    assert_match(/database down/, error.message)
    assert_equal :stopped, session.children.first.status
    retry_provider = fake({ text: "must not run" })
    retried = Mistri::SubAgent.run_dispatched(
      spec, provider: retry_provider, system: "Do the work.", tools: [], store: store
    )

    assert_nil retried
    assert_empty retry_provider.requests
  end

  def test_a_stop_arriving_after_factory_rescue_survives_to_the_retry
    adapter = Class.new(Mistri::Locks::Memory) do
      def arm(key, runner)
        @target = key
        @runner = runner
        @reads = 0
      end

      def flag?(key)
        return super unless key == @target && Thread.current == @runner

        @reads += 1
        return super unless @reads == 2

        set_flag(key)
        false
      end
    end.new
    Mistri.locks = adapter
    spec, store, session = queue
    adapter.arm(Mistri::Child.stop_key(spec.fetch("session_id")), Thread.current)

    assert_raises(RuntimeError) do
      Mistri::SubAgent.run_dispatched(
        spec, store: store, runtime_factory: ->(_owned) { raise "database down" }
      )
    end

    assert_equal :interrupted, session.children.first.status
    assert_empty session.pending_inbox
    provider = fake({ text: "must not run" })
    factory_calls = 0
    result = Mistri::SubAgent.run_dispatched(
      spec, store: store, runtime_factory: lambda do |_owned|
        factory_calls += 1
        Mistri::SubAgent::Runtime.new(provider: provider)
      end
    )

    assert_predicate result, :aborted?
    assert_equal 0, factory_calls
    assert_empty provider.requests
    assert_equal :stopped, session.children.first.status
    assert_equal "stopped", session.pending_inbox.first["status"]
  end

  def test_runtime_subclasses_and_array_subclasses_cannot_bypass_validation
    spec, store, = queue(selected: [])
    provider = fake({ text: "never" })
    subclass = Class.new(Mistri::SubAgent::Runtime)

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(
        spec, store: store, runtime_factory: ->(_owned) { subclass.new(provider: provider) }
      )
    end

    assert_match(/must return Mistri::SubAgent::Runtime/, error.message)
    assert_empty provider.requests

    safe = Mistri::Tool.define("safe", "Safe.") { "safe" }
    danger_called = false
    danger = Mistri::Tool.define("danger", "Danger.") do
      danger_called = true
      "danger"
    end
    spec, store, = queue(tools: [safe])
    deceptive = Class.new(Array) do
      def all?(*) = true
      def map(*) = ["safe"]
      def to_h(*) = { "safe" => first }
    end.new([danger])
    provider = fake({ tool_calls: [{ name: "danger", arguments: {} }] })
    factory = lambda do |_owned|
      Mistri::SubAgent::Runtime.new(provider: provider, tools: deceptive)
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    end

    assert_match(/missing: safe; extra: danger/, error.message)
    refute danger_called
    assert_empty provider.requests
  end

  def test_the_dispatched_lease_is_held_until_the_terminal_is_durable
    adapter = Class.new(Mistri::Locks::Memory) do
      attr_accessor :on_release

      def release(key)
        super
        callback = on_release
        self.on_release = nil
        callback&.call
      end
    end.new
    Mistri.locks = adapter
    spec, store, session = queue
    first_provider = fake({ text: "done once" })
    retry_provider = fake({ text: "must not run" })
    retried = :not_called
    adapter.on_release = lambda do
      retried = Mistri::SubAgent.run_dispatched(spec, provider: retry_provider,
                                                      system: "Do the work.", tools: [],
                                                      store: store)
    end

    result = Mistri::SubAgent.run_dispatched(spec, provider: first_provider,
                                                   system: "Do the work.", tools: [],
                                                   store: store)

    assert_predicate result, :completed?
    assert_nil retried
    assert_empty retry_provider.requests
    assert_equal :done, session.children.first.status
    assert_equal 1, session.pending_inbox.length
  end

  def test_the_dispatched_lease_is_held_through_parent_report_delivery
    Mistri.locks = Mistri::Locks::Memory.new
    store = report_observing_store
    spec, _, session = queue(store: store)
    store.lease_key = Mistri::Child.lease_key(spec.fetch("session_id"))

    result = Mistri::SubAgent.run_dispatched(
      spec, provider: fake({ text: "done" }), system: "Do the work.", tools: [], store: store
    )

    assert_predicate result, :completed?
    assert_equal [true], store.report_lease_states
    assert_equal 1, session.pending_inbox.length
  end

  def test_a_lease_refused_delivery_does_not_report_for_the_owner
    Mistri.locks = Mistri::Locks::Memory.new
    spec, store, session = queue
    child = Mistri::Session.new(store: store, id: spec.fetch("session_id"))
    child.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "owned")
    key = Mistri::Child.lease_key(child.id)
    Mistri.locks.acquire(key, ttl: 60)
    events = []
    provider = fake({ text: "must not run" })
    emit = ->(event) { events << event }
    runtime = { provider: provider, system: "Do the work.", tools: [], store: store, emit: emit }

    result = Mistri::SubAgent.run_dispatched(spec, **runtime)

    assert_nil result
    assert_empty session.pending_inbox
    assert_empty events
  ensure
    Mistri.locks&.release(key) if key
  end

  def test_factory_cannot_impersonate_a_dispatch_grant_failure
    Mistri.locks = Mistri::Locks::Memory.new
    spec, store, session = queue
    factory = lambda do |_owned|
      raise Mistri::DispatchGrantError, "not a queue grant failure"
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    end

    assert_instance_of Mistri::ConfigurationError, error
    assert_instance_of Mistri::DispatchGrantError, error.cause
    assert_equal :interrupted, session.children.first.status
    assert_empty session.pending_inbox

    assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(
        spec, store: store, runtime_factory: factory, retry_factory_errors: false
      )
    end

    assert_equal :failed, session.children.first.status
    assert_equal "failed", session.pending_inbox.first["status"]
  end

  def test_runtime_cleanup_runs_once_without_masking_the_primary_error
    declared = Mistri::Tool.define("declared", "Declared.") { "ok" }
    extra = Mistri::Tool.define("extra", "Extra.") { "no" }
    spec, store, = queue(tools: [declared])
    cleanup_calls = 0
    factory = lambda do |_owned|
      Mistri::SubAgent::Runtime.new(
        provider: fake({ text: "never" }), system: "Do the work.", tools: [declared, extra],
        cleanup: lambda {
          cleanup_calls += 1
          raise "cleanup failed"
        }
      )
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    end

    assert_match(/extra: extra/, error.message)
    refute_match(/cleanup failed/, error.message)
    assert_equal 1, cleanup_calls
  end

  def test_successful_runtime_cleanup_failure_is_visible_after_completion
    spec, store, session = queue
    factory = lambda do |_owned|
      Mistri::SubAgent::Runtime.new(provider: fake({ text: "done" }),
                                    system: "Do the work.",
                                    cleanup: -> { raise "cleanup failed" })
    end

    error = assert_raises(RuntimeError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: factory)
    end

    assert_match(/cleanup failed/, error.message)
    assert_equal :done, session.children.first.status
    assert_equal "done", session.pending_inbox.first["status"]
  end

  def test_unknown_spec_versions_fail_closed
    store = Mistri::Stores::Memory.new
    future = valid_spec
    future["spec_version"] = Mistri::SubAgent::DISPATCH_SPEC_VERSION + 1
    child_session = Mistri::Session.new(store: store, id: future.fetch("session_id"))
    child_session.append(Mistri::Child::DISPATCHED, "spec" => future)
    provider = fake({ text: "never" })

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(future, provider: provider,
                                              system: "Do the work.", tools: [], store: store)
    end

    assert_match(/unsupported dispatched child spec version/, error.message)
    assert_empty provider.requests
    terminal = child_session.entries.reverse.find do |entry|
      entry["type"] == Mistri::Child::TERMINAL
    end

    assert_equal "failed", terminal["status"]
  end

  def test_reconstructed_approval_gates_are_rechecked
    declared = Mistri::Tool.define("risky", "Declared without a gate.") { "ok" }
    spec, store, = queue(tools: [declared])
    gated = Mistri::Tool.define("risky", "Runtime gate.", needs_approval: true) { "no" }
    provider = fake({ text: "never" })
    runtime_factory = lambda do |_owned_spec|
      Mistri::SubAgent::Runtime.new(provider: provider, system: "Do the work.", tools: [gated])
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(spec, store: store, runtime_factory: runtime_factory)
    end

    assert_match(/approval-gated tools/, error.message)
    assert_empty provider.requests
  end

  def test_a_finished_redelivery_does_not_construct_another_runtime
    spec, store, = queue
    provider = fake({ text: "done" })
    Mistri::SubAgent.run_dispatched(spec, provider: provider, system: "Do the work.",
                                          tools: [], store: store)
    calls = 0
    runtime_factory = lambda do |_owned_spec|
      calls += 1
      raise "must not construct"
    end

    result = Mistri::SubAgent.run_dispatched(spec, store: store,
                                                   runtime_factory: runtime_factory)

    assert_nil result
    assert_equal 0, calls
  end

  def test_legacy_specs_with_workspace_remain_executable
    store = Mistri::Stores::Memory.new
    child_session = Mistri::Session.new(store: store)
    child_session.append(Mistri::Child::DISPATCHED, {})
    legacy = valid_spec.merge("session_id" => child_session.id, "workspace" => "own")
    legacy.delete("spec_version")
    provider = fake({ text: "legacy ran" })

    result = Mistri::SubAgent.run_dispatched(legacy, provider: provider,
                                                     system: "Do the work.", tools: [],
                                                     store: store)

    assert_predicate result, :completed?
    child = Mistri::Child.new(name: "Raw", session_id: child_session.id, store: store)

    assert_equal :done, child.status
  end
end
