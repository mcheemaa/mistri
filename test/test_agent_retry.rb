# frozen_string_literal: true

require_relative "test_helper"

# Loop retries: transient turn failures retry with backoff and stay invisible
# to the model; permanent failures and exhausted policies surface honestly.
class TestAgentRetry < Minitest::Test
  FAST = Mistri::RetryPolicy.new(attempts: 2, base: 0.0)

  def test_a_transient_failure_retries_and_recovers
    provider = Mistri::Providers::Fake.new(turns: [
                                             { error: "overloaded", status: 529 },
                                             { text: "recovered" }
                                           ])
    agent = Mistri::Agent.new(provider:, retries: FAST)
    events = []

    result = agent.run("go") { |event| events << event }

    assert_predicate result, :completed?
    assert_equal "recovered", result.text
    assert_equal 2, provider.requests.length

    retry_event = events.find { |e| e.type == :retry }

    assert_match(/retrying/, retry_event.content)
    assert_equal 1, retry_event.attempt
    assert_equal 2, retry_event.max_attempts
    assert_kind_of Float, retry_event.delay
    assert_nil retry_event.reason, "a retry is not a stop"
    refute(events.any? { |e| e.type == :error },
           "the recovered attempt's terminal never reaches the subscriber")
    assert_equal(1, events.count { |e| e.type == :done })

    entries = agent.session.entries

    assert(entries.any? { |e| e["type"] == "retry" && e.dig("error", "status") == 529 })
    refute(agent.session.messages.any? { |m| m.stop_reason == :error },
           "the failed attempt never becomes a message")
  end

  def test_retry_attempt_usage_is_included_in_the_run_total
    failed = Mistri::Usage.new(input: 1_000_000).with_cost(input: 1.0)
    recovered = Mistri::Usage.new(input: 1_000_000).with_cost(input: 1.0)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { error: "overloaded", status: 529, usage: failed },
                                             { text: "recovered", usage: recovered }
                                           ])
    agent = Mistri::Agent.new(provider:, retries: FAST,
                              budget: Mistri::Budget.new(cost_usd: 1.50))

    result = agent.run("go")
    retry_entry = agent.session.entries.find { |entry| entry["type"] == "retry" }

    assert_predicate result, :completed?, "the ceiling is soft through the completed turn"
    assert_in_delta 2.0, result.usage.cost.total
    assert_in_delta 1.0, retry_entry.dig("usage", "cost", "total")
  end

  def test_a_retry_without_usage_records_that_its_cost_is_unknown
    turns = [
      Mistri::Message.assistant(stop_reason: :error, error_message: "overloaded",
                                error: { "type" => "OverloadedError" }),
      Mistri::Message.assistant(content: "recovered", stop_reason: :stop,
                                usage: Mistri::Usage.zero)
    ]
    provider = Mistri::Providers::Fake.new
    provider.define_singleton_method(:stream) { |**_options| turns.shift }
    agent = Mistri::Agent.new(provider:, retries: FAST)

    result = agent.run("go")
    retry_entry = agent.session.entries.find { |entry| entry["type"] == "retry" }

    refute_predicate result.usage.cost, :known?
    refute retry_entry.dig("usage", "cost", "known")
  end

  def test_a_cost_budget_does_not_retry_an_unmetered_failure
    calls = 0
    turns = [
      Mistri::Message.assistant(stop_reason: :error, error_message: "overloaded",
                                error: { "type" => "OverloadedError" }),
      Mistri::Message.assistant(content: "must not run", stop_reason: :stop,
                                usage: Mistri::Usage.zero)
    ]
    provider = Mistri::Providers::Fake.new
    provider.define_singleton_method(:stream) do |**_options|
      calls += 1
      turns.shift
    end
    agent = Mistri::Agent.new(provider:, retries: FAST,
                              budget: Mistri::Budget.new(cost_usd: 1.00))
    events = []

    error = assert_raises(Mistri::BudgetError) do
      agent.run("go") { |event| events << event }
    end
    entry = agent.session.entries.find { |item| item["type"] == "unpriced_attempt" }

    assert_match(/not retrying/, error.message)
    assert_equal "overloaded", error.provider_message.error_message
    refute_predicate error.usage.cost, :known?
    assert_equal "turn", entry["kind"]
    assert_equal 1, events.count(&:terminal?)
    assert_equal Mistri::StopReason::BUDGET, events.last.reason
    assert_equal Mistri::StopReason::BUDGET, agent.session.messages.last.stop_reason
    assert_equal 1, calls
    refute(agent.session.entries.any? { |entry| entry["type"] == "retry" })
  end

  # Providers intermittently finish with an empty candidate: no text, no
  # tool calls, nothing. That is never a real answer, so it retries like a
  # transient failure instead of ending the run in silence.
  def test_an_empty_completion_retries_and_recovers
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: "\n" },
                                             { text: "a real answer" }
                                           ])
    agent = Mistri::Agent.new(provider:, retries: FAST)

    result = agent.run("go")

    assert_predicate result, :completed?
    assert_equal "a real answer", result.text
    assert_equal 2, provider.requests.length
    assert(agent.session.entries.any? do |e|
      e["type"] == "retry" && e.dig("error", "type") == "EmptyCompletion"
    end)
  end

  def test_a_still_empty_completion_returns_after_retries_exhaust
    provider = Mistri::Providers::Fake.new(turns: [{ text: "" }, { text: "" }, { text: "" }])
    agent = Mistri::Agent.new(provider:, retries: FAST)
    events = []

    result = agent.run("go") { |event| events << event }

    assert_predicate result, :completed?
    assert_equal 3, provider.requests.length, "two retries, then the answer stands as it is"
    assert_equal 1, events.count(&:terminal?), "only the accepted attempt's :done surfaces"
  end

  def test_a_permanent_failure_fails_fast
    provider = Mistri::Providers::Fake.new(turns: [{ error: "bad request", status: 400 }])
    agent = Mistri::Agent.new(provider:, retries: FAST)
    events = []

    result = agent.run("go") { |event| events << event }

    assert_predicate result, :errored?
    assert_equal 1, provider.requests.length
    assert_empty(events.select { |e| e.type == :retry })
  end

  def test_scripted_errors_without_a_status_stay_non_retryable
    provider = Mistri::Providers::Fake.new(turns: [{ error: "boom" }])

    result = Mistri::Agent.new(provider:, retries: FAST).run("go")

    assert_predicate result, :errored?
    assert_equal 1, provider.requests.length
  end

  def test_an_exhausted_policy_surfaces_the_last_error_with_its_data
    turns = Array.new(3) { { error: "overloaded", status: 529 } }
    provider = Mistri::Providers::Fake.new(turns:)
    agent = Mistri::Agent.new(provider:, retries: FAST)

    events = []
    result = agent.run("go") { |event| events << event }

    assert_predicate result, :errored?
    assert_equal 3, provider.requests.length, "attempts 2 means three requests"
    assert_equal 529, agent.session.messages.last.error["status"],
                 "the machine-readable failure persists with the message"
    assert_equal(2, agent.session.entries.count { |e| e["type"] == "retry" })
    assert_equal 1, events.count { |e| e.type == :error },
                 "exhaustion surfaces exactly one terminal error"
    assert_equal [1, 2], events.select { |e| e.type == :retry }.map(&:attempt)
  end

  def test_retries_false_disables_the_policy
    provider = Mistri::Providers::Fake.new(turns: [{ error: "overloaded", status: 529 }])

    result = Mistri::Agent.new(provider:, retries: false).run("go")

    assert_predicate result, :errored?
    assert_equal 1, provider.requests.length
  end

  def test_an_abort_cuts_the_backoff_short
    provider = Mistri::Providers::Fake.new(turns: [{ error: "overloaded", status: 529 }])
    signal = Mistri::AbortSignal.new
    slow = Mistri::RetryPolicy.new(attempts: 1, base: 60.0)
    agent = Mistri::Agent.new(provider:, retries: slow)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = agent.run("go", signal: signal) do |event|
      signal.abort! if event.type == :retry
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_predicate result, :errored?
    assert_operator elapsed, :<, 5.0, "the abort ended the backoff, not the timer"
    assert_equal 1, provider.requests.length, "no retry request after the abort"
  end
end
