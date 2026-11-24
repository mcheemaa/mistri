# frozen_string_literal: true

require_relative "test_helper"

class TestToolAbortBoundaries < Minitest::Test
  def test_a_normalizer_abort_stops_before_the_validator
    signal = Mistri::AbortSignal.new
    phases = []
    tool = Mistri::Tool.define(
      "write", "Writes.",
      argument_normalizer: lambda { |arguments|
        phases << :normalizer
        signal.abort!(:test)
        arguments
      },
      argument_validator: lambda { |*|
        phases << :validator
        []
      }
    ) { flunk "handler ran" }
    provider = two_call_fake("write", "write")
    agent = Mistri::Agent.new(provider:, tools: [tool])

    result = agent.run("go", signal:)

    assert_predicate result, :aborted?
    assert_equal [:normalizer], phases
  end

  def test_after_tool_skips_a_queued_call_that_never_committed
    signal = Mistri::AbortSignal.new
    rewritten = []
    first = Mistri::Tool.define("first", "First.") do
      signal.abort!(:test)
      "done"
    end
    second = Mistri::Tool.define("second", "Second.") { flunk "queued handler ran" }
    provider = two_call_fake("first", "second")
    agent = Mistri::Agent.new(
      provider:, tools: [first, second], max_concurrency: 1,
      after_tool: lambda { |call, result, _context|
        rewritten << call.name
        result
      }
    )

    result = agent.run("go", signal:)

    assert_predicate result, :aborted?
    assert_equal ["first"], rewritten
    assert_equal ["done", Mistri::ToolExecutor::INTERRUPTED],
                 agent.session.messages.select(&:tool?).map(&:text)
  end

  def test_a_queued_call_of_one_step_never_starts_after_an_abort
    signal = Mistri::AbortSignal.new
    first = Mistri::Tool.define("first", "First.", parallel: true) do
      signal.abort!(:test)
      "done"
    end
    second = Mistri::Tool.define("second", "Second.", parallel: true) do
      flunk "queued handler ran"
    end
    agent = Mistri::Agent.new(provider: two_call_fake("first", "second"),
                              tools: [first, second], max_concurrency: 1)

    result = agent.run("go", signal:)

    assert_predicate result, :aborted?
    assert_equal ["done", Mistri::ToolExecutor::INTERRUPTED],
                 agent.session.messages.select(&:tool?).map(&:text)
  end

  def test_an_abort_while_an_approved_call_runs_interrupts_the_approved_call_after_it
    signal = Mistri::AbortSignal.new
    first = Mistri::Tool.define("first", "First.", needs_approval: true) do
      signal.abort!(:test)
      "done"
    end
    second = Mistri::Tool.define("second", "Second.", needs_approval: true) do
      flunk "handler ran after the abort"
    end
    agent = Mistri::Agent.new(provider: two_call_fake("first", "second"), tools: [first, second])
    agent.run("go").pending.each { |call| agent.session.approve(call.id) }

    result = agent.resume(signal:)

    assert_predicate result, :aborted?
    assert_equal ["done", Mistri::ToolExecutor::INTERRUPTED],
                 agent.session.messages.select(&:tool?).map(&:text)
  end

  private

  def two_call_fake(*names)
    calls = names.map { |name| { name:, arguments: {} } }
    Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }])
  end
end
