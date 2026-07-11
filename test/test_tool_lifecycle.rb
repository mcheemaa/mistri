# frozen_string_literal: true

require_relative "test_helper"

# Tool lifecycle events distinguish execution commitment from typed outcomes.
class TestToolLifecycle < Minitest::Test
  def test_lifecycle_is_typed_without_sniffing_content
    seen_before_each_handler = []
    starts = []
    first = Mistri::Tool.define("first", "First.") do
      seen_before_each_handler << starts.dup
      "Error is just the first word of this successful result"
    end
    second = Mistri::Tool.define("second", "Second.") do
      seen_before_each_handler << starts.dup
      Mistri::ToolResult.new(content: "ordinary text", error: true)
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "first", arguments: {} },
                                                            { name: "second", arguments: {} }] },
                                             { text: "done" }
                                           ])
    results = []

    Mistri::Agent.new(provider:, tools: [first, second], max_concurrency: 1).run("go") do |event|
      starts << event.tool_call.name if event.type == :tool_started
      results << event if event.type == :tool_result
    end

    assert_equal [["first"], %w[first second]], seen_before_each_handler,
                 "a queued call announces only when its own handler is next"
    assert_equal [false, true], results.map(&:tool_error)
    assert_equal([false, true], results.map { |event| event.message.tool_error })
  end

  def test_unknown_tools_fail_without_claiming_execution_started
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "missing", arguments: {} }] },
                                             { text: "recovered" }
                                           ])
    events = []

    Mistri::Agent.new(provider:).run("go") { |event| events << event }

    refute(events.any? { |event| event.type == :tool_started })
    result = events.find { |event| event.type == :tool_result }

    assert result.tool_error
    assert_nil result.duration
  end

  def test_a_start_subscriber_error_propagates_without_running_the_tool
    ran = false
    tool = Mistri::Tool.define("write", "Writes.") do
      ran = true
      "written"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "write", arguments: {} }] }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool])

    error = assert_raises(RuntimeError) do
      agent.run("go") { |event| raise "subscriber failed" if event.type == :tool_started }
    end

    assert_equal "subscriber failed", error.message
    refute ran
    tool_ids = agent.session.entries.filter_map { |entry| entry.dig("message", "tool_call_id") }

    assert_empty tool_ids
  end

  def test_a_start_subscriber_error_latches_before_another_worker_can_commit
    resolved = Queue.new
    ran = []
    definitions = %w[a b].to_h do |name|
      tool = Mistri::Tool.define(name, "Runs.") do
        ran << name
        name
      end
      [name, tool]
    end
    lookup = Object.new
    lookup.define_singleton_method(:[]) do |name|
      resolved << name
      definitions[name]
    end
    calls = %w[a b].map { |name| Mistri::ToolCall.new(id: name, name:, arguments: {}) }
    started = []
    emit = lambda do |event|
      next unless event.type == :tool_started

      2.times { resolved.pop } if started.empty?
      started << event.tool_call.name
      raise "subscriber failed"
    end

    error = assert_raises(RuntimeError) do
      Mistri::ToolExecutor.call(calls, lookup, max_concurrency: 2, emit:)
    end

    assert_equal "subscriber failed", error.message
    assert_equal 1, started.length
    assert_empty ran, "no handler commits after the subscriber boundary fails"
  end

  def test_a_progress_subscriber_error_is_not_mislabeled_as_a_handler_failure
    later_ran = false
    progress = Mistri::Tool.define("progress", "Reports progress.") do |_args, context|
      context.emit.call(Mistri::Event.new(type: :compacting))

      flunk "continued after its progress subscriber failed"
    end
    later = Mistri::Tool.define("later", "Runs later.") do
      later_ran = true
      "done"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "progress", arguments: {} },
                                                            { name: "later", arguments: {} }] }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [progress, later], max_concurrency: 1)

    error = assert_raises(IOError) do
      agent.run("go") { |event| raise IOError, "subscriber failed" if event.type == :compacting }
    end

    assert_equal "subscriber failed", error.message
    refute later_ran
    tool_ids = agent.session.entries.filter_map { |entry| entry.dig("message", "tool_call_id") }

    assert_empty tool_ids, "subscriber failures never persist as tool outcomes"
  end

  def test_a_configured_timeout_inside_progress_delivery_remains_a_tool_timeout
    tool = Mistri::Tool.define("progress", "Reports progress.", timeout: 0.05) do |_args, context|
      context.emit.call(Mistri::Event.new(type: :compacting))
      "done"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "progress",
                                                              arguments: {} }] },
                                             { text: "recovered" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool])

    agent.run("go") { |event| sleep 0.2 if event.type == :compacting }

    answer = agent.session.messages.select(&:tool?).last

    assert_includes answer.text, "timed out after 0.05s"
    assert_predicate answer, :tool_error?
  end

  def test_a_worker_that_dies_after_start_returns_an_unknown_outcome
    tool = Mistri::Tool.define("exit", "Exits its worker.") { Thread.exit }
    call = Mistri::ToolCall.new(id: "c1", name: "exit", arguments: {})
    events = []

    emit = lambda do |event|
      events << event
    end
    result = Mistri::ToolExecutor.call([call], { "exit" => tool }, emit:).first

    assert_equal [:tool_started], events.map(&:type)
    assert_predicate result[1], :error?
    assert_equal Mistri::ToolExecutor::OUTCOME_UNKNOWN, result[1].content
    assert_match(/verify.*before retrying/i, result[1].content)
    assert_nil result[2]
  end

  def test_parallel_results_keep_model_order_after_the_batch_joins
    release = Queue.new
    slow_started = Queue.new
    fast_done = Queue.new
    events = Queue.new
    slow = Mistri::Tool.define("slow", "Slow.") do
      slow_started << true
      release.pop
      "slow result"
    end
    fast = Mistri::Tool.define("fast", "Fast.") do
      fast_done << true
      "fast result"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "slow", arguments: {} },
                                                            { name: "fast", arguments: {} }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [slow, fast], max_concurrency: 2)
    run = Thread.new { agent.run("go") { |event| events << event } }

    slow_started.pop
    fast_done.pop
    before_release = []
    before_release << events.pop until events.empty?

    refute(before_release.any? { |event| event.type == :tool_result },
           "a fast sibling result waits for the deterministic batch barrier")
    release << true
    run.value
    arrived = before_release
    arrived << events.pop until events.empty?
    result_names = arrived.select { |event| event.type == :tool_result }
                          .map { |event| event.tool_call.name }

    assert_equal %w[slow fast], result_names
  ensure
    release << true if release && release.empty?
    run&.join
  end
end
