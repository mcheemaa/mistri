# frozen_string_literal: true

require_relative "test_helper"

# Subscriber failures retain their identity across every synchronous boundary.
class TestSubscriberBoundaries < Minitest::Test
  def test_before_tool_subscriber_failure_is_not_a_policy_result
    failure = Mistri::ConfigurationError.new("subscriber failed")
    ran = []
    hook = lambda do |_call, context|
      context.emit.call(Mistri::Event.new(type: :compacting))

      flunk "hook continued after delivery failed"
    end
    tool = Mistri::Tool.define("write", "Writes.") { ran << :handler }
    agent = tool_agent(tool, before_tool: hook)
    events = []

    raised = assert_raises(Mistri::ConfigurationError) do
      agent.run("go") do |event|
        events << event.type
        raise failure if event.type == :compacting
      end
    end

    assert_same failure, raised
    assert_empty ran
    refute_includes events, :tool_result
    assert_empty persisted_tool_entries(agent.session)
  end

  def test_after_tool_subscriber_failure_is_not_a_result_hook_failure
    failure = IOError.new("subscriber failed")
    ran = []
    hook = lambda do |_call, _result, context|
      context.emit.call(Mistri::Event.new(type: :compacting))

      flunk "hook continued after delivery failed"
    end
    tool = Mistri::Tool.define("write", "Writes.") do
      ran << :handler
      "written"
    end
    agent = tool_agent(tool, after_tool: hook)
    events = []

    raised = assert_raises(IOError) do
      agent.run("go") do |event|
        events << event.type
        raise failure if event.type == :compacting
      end
    end

    assert_same failure, raised
    assert_equal [:handler], ran
    refute_includes events, :tool_result
    assert_empty persisted_tool_entries(agent.session)
  end

  def test_automatic_compaction_propagates_colliding_subscriber_errors
    %i[compacting compaction].each do |event_type|
      failure = Mistri::CompactionError.new("subscriber failed")
      agent, provider = compaction_agent
      agent.run("first question")

      raised = assert_raises(Mistri::CompactionError) do
        agent.run("second question") do |event|
          raise failure if event.type == event_type
        end
      end

      assert_same failure, raised
      if event_type == :compacting
        assert_equal 1, provider.requests.length
        assert_nil agent.session.last_compaction
      else
        assert_equal 2, provider.requests.length
        assert_equal "durable summary", agent.session.last_compaction.fetch("summary")
      end
    end
  end

  def test_a_genuine_automatic_compaction_failure_is_still_skipped
    usage = Mistri::Usage.new(input: 900, output: 100)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: "old answer " * 50, usage: usage },
                                             { error: "summarizer unavailable" },
                                             { text: "new answer" }
                                           ])
    settings = Mistri::Compaction.new(window: 1_000, reserve: 50, keep_recent: 10)
    agent = Mistri::Agent.new(provider:, compaction: settings)
    agent.run("first question")

    result = agent.run("second question")

    assert_predicate result, :completed?
    assert_equal "new answer", result.text
    assert_nil agent.session.last_compaction
    assert_equal 3, provider.requests.length
  end

  def test_parallel_progress_reuses_the_first_subscriber_failure
    release = Queue.new
    tools = %w[first second].to_h do |name|
      [name, Mistri::Tool.define(name, "Reports progress.") do |_args, context|
        release.pop
        context.emit.call(Mistri::Event.new(type: :compacting))

        flunk "handler continued after delivery failed"
      end]
    end
    calls = tools.keys.map do |name|
      Mistri::ToolCall.new(id: name, name:, arguments: {})
    end
    starts = 0
    progress_calls = 0
    failure = IOError.new("subscriber failed")
    emit = lambda do |event|
      if event.type == :tool_started
        starts += 1
        2.times { release << true } if starts == 2
      elsif event.type == :compacting
        progress_calls += 1
        raise failure
      end
    end

    raised = assert_raises(IOError) do
      Mistri::ToolExecutor.call(calls, tools, max_concurrency: 2, emit:)
    end

    assert_same failure, raised
    assert_equal 1, progress_calls
  end

  def test_a_background_report_failure_keeps_durable_success_and_diagnoses_the_original
    previous_locks = Mistri.locks
    Mistri.locks = nil
    child_provider = Mistri::Providers::Fake.new(turns: [{ text: "child done" }])
    runtime_factory = lambda do |_spec|
      Mistri::SubAgent::Runtime.new(provider: child_provider, tools: [])
    end
    spawn = Mistri::SubAgent.spawner(provider: child_provider,
                                     dispatcher: Mistri::Dispatchers::Thread.new,
                                     runtime_factory:)
    parent_provider = Mistri::Providers::Fake.new(turns: [
                                                    { tool_calls: [{ name: "spawn_agent",
                                                                     arguments: {
                                                                       name: "Scout",
                                                                       task: "report",
                                                                       instructions: "Report.",
                                                                       mode: "background"
                                                                     } }] },
                                                    { text: "parent done" }
                                                  ])
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    agent = Mistri::Agent.new(provider: parent_provider, tools: [spawn], session:)
    attempted = Queue.new
    failure = IOError.new("subscriber failed")
    result = nil

    _stdout, stderr = capture_io do
      result = agent.run("delegate") do |event|
        next unless event.type == :subagent_report

        attempted << true
        raise failure
      end
      Timeout.timeout(3) { attempted.pop }
      wait_until { $stderr.string.include?("background runner") }
    end

    assert_predicate result, :completed?
    child = session.children.fetch(0)

    assert_equal :done, child.status
    assert_equal "child done", child.report
    report = session.entries.find { |entry| entry["type"] == "subagent_report" }

    assert_equal "done", report["status"]
    assert_includes stderr, "IOError: subscriber failed"
    refute_includes stderr, "EventDelivery::Failure"
  ensure
    Mistri.locks = previous_locks
  end

  private

  def tool_agent(tool, **)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: tool.name, arguments: {} }] }
                                           ])
    Mistri::Agent.new(provider:, tools: [tool], **)
  end

  def persisted_tool_entries(session)
    session.entries.select do |entry|
      entry["type"] == "message" && entry.dig("message", "role") == "tool"
    end
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until yield
      raise "timed out waiting for the background diagnostic" if Process.clock_gettime(
        Process::CLOCK_MONOTONIC
      ) >= deadline

      Thread.pass
    end
  end

  def compaction_agent
    usage = Mistri::Usage.new(input: 900, output: 100)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: "old answer " * 50, usage: usage },
                                             { text: "durable summary" },
                                             { text: "new answer" }
                                           ])
    settings = Mistri::Compaction.new(window: 1_000, reserve: 50, keep_recent: 10)
    [Mistri::Agent.new(provider:, compaction: settings), provider]
  end
end
