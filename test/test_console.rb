# frozen_string_literal: true

require_relative "test_helper"

# The management console: four stateless tools over the children registry,
# uniform name-or-id addressing, honest in-band answers for every state.
class TestConsole < Minitest::Test
  def teardown
    Mistri.locks = nil
  end

  def context_for(session)
    Mistri::ToolContext.new(session: session, signal: nil, emit: nil, app: nil)
  end

  def link(parent, store, name)
    child = Mistri::Session.new(store:)
    parent.append("subagent", "name" => name, "session_id" => child.id)
    child
  end

  def setup_family
    store = Mistri::Stores::Memory.new
    parent = Mistri::Session.new(store:)
    done = link(parent, store, "Corgi")
    done.append_message(Mistri::Message.user("find the answer"))
    done.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "The answer is 42.")
    running = link(parent, store, "Husky")
    running.append_message(Mistri::Message.user("long task"))
    [store, parent, done, running]
  end

  def test_list_agents_shows_every_worker_with_status
    _store, parent, = setup_family
    output = Mistri::Console.list_agents.call({}, context_for(parent))

    assert_match(/Corgi \(\h{8}\): done/, output)
    assert_match(/Husky \(\h{8}\): running/, output)
  end

  def test_list_agents_with_no_workers_says_so
    parent = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    assert_equal "You have no workers.", Mistri::Console.list_agents.call({}, context_for(parent))
  end

  def test_read_agent_renders_a_compact_transcript
    _store, parent, = setup_family
    output = Mistri::Console.read_agent.call({ "agent" => "Corgi" }, context_for(parent))

    assert_match(/Corgi \(done\)/, output)
    assert_match(/user: find the answer/, output)
    assert_match(/done: The answer is 42\./, output)
  end

  def test_read_agent_tails_to_the_requested_length
    _store, parent, _done, running = setup_family
    3.times { |i| running.append_message(Mistri::Message.user("note #{i}")) }
    output = Mistri::Console.read_agent.call({ "agent" => "Husky", "tail" => 2 },
                                             context_for(parent))

    assert_match(/last 2 entries/, output)
    refute_match(/long task/, output)
  end

  def test_read_agent_wait_returns_the_report_once_finished
    _store, parent, done, = setup_family
    output = Mistri::Console.read_agent(timeout: 1, poll: 0.05)
                            .call({ "agent" => done.id, "wait" => true }, context_for(parent))

    assert_match(/Corgi done\./, output)
    assert_match(/The answer is 42\./, output)
  end

  def test_read_agent_wait_times_out_in_band
    Mistri.locks = Mistri::Locks::Memory.new
    _store, parent, _done, running = setup_family
    Mistri.locks.acquire(Mistri::Child.lease_key(running.id), ttl: 60)
    output = Mistri::Console.read_agent(timeout: 0.15, poll: 0.05)
                            .call({ "agent" => "Husky", "wait" => true }, context_for(parent))

    assert_match(/still running/, output)
  end

  def test_steer_agent_queues_on_a_running_worker_and_refuses_a_finished_one
    _store, parent, done, running = setup_family
    context = context_for(parent)

    queued = Mistri::Console.steer_agent.call(
      { "agent" => "Husky", "message" => "check the pricing page too" }, context
    )

    assert_match(/Queued/, queued)
    assert_equal 1, Mistri::Session.new(store: running.store, id: running.id)
                                   .pending_steers.length

    refused = Mistri::Console.steer_agent.call(
      { "agent" => done.id, "message" => "anything" }, context
    )

    assert_match(/is done, so there is nothing to steer/, refused)
  end

  def test_stop_agent_sets_the_flag_and_answers_every_state_honestly
    Mistri.locks = Mistri::Locks::Memory.new
    _store, parent, done, running = setup_family
    Mistri.locks.acquire(Mistri::Child.lease_key(running.id), ttl: 60)
    context = context_for(parent)

    stopped = Mistri::Console.stop_agent.call({ "agent" => "Husky" }, context)

    assert_match(/Stop requested/, stopped)
    assert Mistri.locks.flag?(Mistri::Child.stop_key(running.id))

    already = Mistri::Console.stop_agent.call({ "agent" => done.id }, context)

    assert_match(/already done/, already)
  end

  def test_stop_agent_without_an_adapter_answers_in_band
    _store, parent, _done, _running = setup_family
    output = Mistri::Console.stop_agent.call({ "agent" => "Husky" }, context_for(parent))

    assert_match(/needs a lock adapter/, output)
  end

  def test_unknown_workers_answer_with_the_roster
    _store, parent, = setup_family
    output = Mistri::Console.read_agent.call({ "agent" => "Poodle" }, context_for(parent))

    assert_match(/No worker matches "Poodle"/, output)
    assert_match(/Corgi, Husky/, output)
  end

  def test_duplicate_names_resolve_to_the_latest_spawn
    store = Mistri::Stores::Memory.new
    parent = Mistri::Session.new(store:)
    first = link(parent, store, "Corgi")
    first.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "old")
    second = link(parent, store, "Corgi")
    second.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "new")

    output = Mistri::Console.read_agent.call({ "agent" => "Corgi", "wait" => true },
                                             context_for(parent))

    assert_match(/new/, output)
    by_id = Mistri::Console.read_agent.call({ "agent" => first.id, "wait" => true },
                                            context_for(parent))

    assert_match(/old/, by_id, "ids stay unambiguous when names collide")
  end
end
