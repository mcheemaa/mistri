# frozen_string_literal: true

require_relative "test_helper"

# Report delivery: a background child's terminal outcome reaches its parent
# exactly once — a typed inbox entry that folds like a steer, and an event
# that closes the child's lane — and the lease fences dispatched runs so
# queue retries heal crashes without ever double-running a child.
class TestReportDelivery < Minitest::Test
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
        nil
      end
    end.new
  end

  def await(deadline: 3)
    ends = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > ends
  end

  # Dispatch through a dropper, then run the job by hand: everything is
  # deterministic and the spec is exactly what a queue would carry.
  def dispatch(child_fake, name: "Basset", tools: [])
    dropper = drop_dispatcher
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: tools, dispatcher: dropper)
    parent = spawn_call({ "name" => name, "task" => "t", "instructions" => "You help.",
                          "mode" => "background" })
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")
    [dropper.spec, store, session]
  end

  def test_a_finished_worker_reports_into_the_parents_inbox
    child_fake = fake({ text: "The answer is 7." })
    spec, store, session = dispatch(child_fake)
    events = []

    Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                          tools: [], store: store,
                                          emit: ->(event) { events << event })

    report = session.pending_inbox.first

    assert_equal "subagent_report", report["type"]
    assert_equal "Basset", report["name"]
    assert_equal spec.fetch("session_id"), report["session_id"]
    assert_equal "done", report["status"]
    assert_equal "The answer is 7.", report["report"]
    assert_equal "[Basset finished] The answer is 7.",
                 report.dig("message", "content", 0, "text")

    event = events.find { |e| e.type == :subagent_report }

    assert_equal "Basset", event.agent
    assert_equal :done, event.status
    assert_equal "The answer is 7.", event.content
  end

  def test_the_report_folds_at_the_parents_next_turn
    child_fake = fake({ text: "Their pricing starts at $49." })
    spec, store, session = dispatch(child_fake, name: "Beagle")
    Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                          tools: [], store: store)
    entry_id = session.pending_inbox.first["id"]
    parent = fake({ text: "Noted, folding that in." })

    Mistri::Agent.new(provider: parent, session:).run("continue")

    folded = session.entries.find { |entry| entry["report_id"] == entry_id }

    refute_nil folded, "the folding message entry marks the report consumed"
    assert_includes parent.requests.first[:messages].map(&:text).join("\n"),
                    "[Beagle finished] Their pricing starts at $49."
    assert_empty session.pending_inbox
  end

  def test_a_report_landing_mid_final_turn_extends_the_run_so_the_parent_reacts
    parent = fake({ text: "All done here." }, { text: "Thanks, Corgi: it is 42." })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    delivered = false

    # The worker finishes while the model is mid-way through its clean
    # final turn — too late for that turn's fold, so the run extends.
    result = Mistri::Agent.new(provider: parent, session:).run("go") do |event|
      next if delivered || event.type != :text_end

      delivered = true
      session.deliver_report(name: "Corgi", session_id: "abc", status: "done", text: "42")
    end

    assert_equal "Thanks, Corgi: it is 42.", result.text,
                 "a clean finish with a pending report runs one more turn"
    assert_includes parent.requests.last[:messages].map(&:text).join("\n"),
                    "[Corgi finished] 42"
    assert_empty session.pending_inbox
  end

  def test_a_failed_worker_reports_the_error
    child_fake = fake({ error: "exploded" })
    spec, store, session = dispatch(child_fake, name: "Husky")

    Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                          tools: [], store: store)

    report = session.pending_inbox.first

    assert_equal "failed", report["status"]
    assert_match(/\[Husky failed\] .*exploded/, report.dig("message", "content", 0, "text"))
    assert_match(/exploded/, Mistri::Child.new(name: "Husky",
                                               session_id: spec.fetch("session_id"),
                                               store: store).error)
  end

  def test_a_stopped_worker_reports_it_was_stopped
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    slow = Mistri::Tool.define("slow", "Takes a while.") do
      sleep 1.4
      "worked"
    end
    child_fake = fake({ tool_calls: [{ name: "slow", arguments: {} }] }, { text: "never" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [slow],
                                     dispatcher: Mistri::Dispatchers::Thread.new)
    parent = spawn_call({ "name" => "Pointer", "task" => "work",
                          "instructions" => "Use slow.", "mode" => "background" })
    session = Mistri::Session.new(store:)
    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")
    child = session.children.first

    child.stop
    await { session.pending_inbox.any? }

    report = session.pending_inbox.first

    assert_equal "stopped", report["status"]
    assert_equal "[Pointer was stopped]", report.dig("message", "content", 0, "text")
    assert_nil report["report"]
  end

  def test_delivery_is_idempotent_and_labels_unknown_statuses_honestly
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    first = session.deliver_report(name: "Corgi", session_id: "abc", status: "done", text: "42")
    second = session.deliver_report(name: "Corgi", session_id: "abc", status: "done", text: "42")

    assert first
    refute second, "the second delivery for the same child is dropped"
    assert_equal 1, session.pending_inbox.length

    session.deliver_report(name: "Akita", session_id: "def", status: "interrupted")

    assert_equal "[Akita ended: interrupted]",
                 session.pending_inbox.last.dig("message", "content", 0, "text")
  end

  def test_steers_and_reports_fold_in_arrival_order
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.steer("check their pricing")
    session.deliver_report(name: "Corgi", session_id: "abc", status: "done", text: "42")
    session.steer("and be quick")
    parent = fake({ text: "On it." })

    Mistri::Agent.new(provider: parent, session:).run("go")

    texts = parent.requests.first[:messages].map(&:text)
    positions = ["check their pricing", "[Corgi finished] 42", "and be quick"]
                .map { |needle| texts.index { |text| text.include?(needle) } }

    assert_equal positions.sort, positions, "the inbox folds in arrival order"
    refute_includes positions, nil
    assert_empty session.pending_inbox
  end

  def test_a_crashed_workers_retry_runs_it_again
    Mistri.locks = Mistri::Locks::Memory.new
    child_fake = fake({ text: "Recovered on retry." })
    spec, store, session = dispatch(child_fake, name: "Saluki")
    child_session = Mistri::Session.new(store:, id: spec.fetch("session_id"))
    # The first delivery started the child, then its process died: a
    # started entry, no terminal, no live lease.
    child_session.append(Mistri::Child::STARTED, {})
    child = session.children.first

    assert_equal :interrupted, child.status

    result = Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                                   tools: [], store: store)

    assert_predicate result, :completed?
    assert_equal :done, child.status
    assert_equal "Recovered on retry.", session.pending_inbox.first["report"]
  end

  def test_a_redelivered_live_job_leaves_the_owner_alone
    Mistri.locks = Mistri::Locks::Memory.new
    child_fake = fake({ text: "should never run" })
    spec, store, session = dispatch(child_fake, name: "Whippet")
    child_session = Mistri::Session.new(store:, id: spec.fetch("session_id"))
    child_session.append(Mistri::Child::STARTED, {})
    Mistri.locks.acquire(Mistri::Child.lease_key(spec.fetch("session_id")), ttl: 30)

    result = Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                                   tools: [], store: store)

    assert_nil result
    assert_empty child_fake.requests, "the redelivered job never ran the child"
    assert_equal :running, session.children.first.status
    assert_empty session.pending_inbox
  end

  def test_a_retry_of_a_finished_job_neither_runs_nor_repeats_the_report
    child_fake = fake({ text: "done once" })
    spec, store, session = dispatch(child_fake)
    Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                          tools: [], store: store)
    events = []

    retried = Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                                    tools: [], store: store,
                                                    emit: ->(event) { events << event })

    assert_nil retried
    assert_equal 1, session.pending_inbox.length
    assert_empty events, "a dropped duplicate delivers no event either"
  end

  def test_a_cancelled_queued_worker_still_reports_when_the_job_arrives_late
    Mistri.locks = Mistri::Locks::Memory.new
    child_fake = fake({ text: "never" })
    spec, store, session = dispatch(child_fake, name: "Collie")
    session.children.first.stop

    Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                          tools: [], store: store)

    report = session.pending_inbox.first

    assert_equal "stopped", report["status"]
    assert_equal "[Collie was stopped]", report.dig("message", "content", 0, "text")
    assert_empty child_fake.requests
  end

  def test_a_parentless_spec_still_emits_the_event
    child_fake = fake({ text: "orphan work" })
    store = Mistri::Stores::Memory.new
    child = Mistri::Session.new(store:)
    child.append(Mistri::Child::DISPATCHED, {})
    # The wire shape, hand-authored: a spec is only JSON.
    spec = { "name" => "Vizsla", "session_id" => child.id, "parent_session_id" => nil,
             "task" => "t", "type" => "general-purpose", "instructions" => "You help.",
             "tool_names" => [], "model" => nil, "workspace" => "own" }
    events = []

    result = Mistri::SubAgent.run_dispatched(spec, provider: child_fake, system: "You help.",
                                                   tools: [], store: store,
                                                   emit: ->(event) { events << event })

    assert_predicate result, :completed?
    assert_equal :subagent_report, events.last.type
    assert_equal "orphan work", events.last.content
  end
end
