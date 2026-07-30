# frozen_string_literal: true

require_relative "test_helper"

# The live ring's transient-retry helper: classification comes from the
# gem's own RetryPolicy, so live tests ride out exactly what the loop
# itself would retry and fail fast on everything else.
class TestTransientRetries < Minitest::Test
  def stream(provider)
    provider.stream(messages: [Mistri::Message.user("Reply with exactly: ok")]) { |_event| nil }
  end

  def test_a_clean_result_returns_without_retrying
    provider = Mistri::Providers::Fake.new(turns: [{ text: "ok" }, { text: "never" }])

    message = Mistri::Test.retry_transient(pause: 0) { stream(provider) }

    assert_equal :stop, message.stop_reason
    assert_equal 1, provider.requests.length
  end

  def test_transient_errors_retry_until_one_succeeds
    provider = Mistri::Providers::Fake.new(turns: [
                                             { error: "overloaded", status: 529 },
                                             { error: "rate limited", status: 429 },
                                             { text: "recovered" }
                                           ])

    message = Mistri::Test.retry_transient(pause: 0) { stream(provider) }

    assert_equal :stop, message.stop_reason
    assert_equal 3, provider.requests.length
  end

  def test_exhausted_attempts_return_the_last_errored_result
    provider = Mistri::Providers::Fake.new(turns: Array.new(3) { { error: "down", status: 503 } })

    message = Mistri::Test.retry_transient(attempts: 3, pause: 0) { stream(provider) }

    assert_equal :error, message.stop_reason
    assert_equal 3, provider.requests.length
  end

  def test_non_transient_errors_fail_fast
    provider = Mistri::Providers::Fake.new(turns: [
                                             { error: "model not found", status: 404 },
                                             { text: "never" }
                                           ])

    message = Mistri::Test.retry_transient(pause: 0) { stream(provider) }

    assert_equal :error, message.stop_reason
    assert_equal 1, provider.requests.length
  end
end
