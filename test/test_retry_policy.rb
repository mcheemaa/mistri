# frozen_string_literal: true

require_relative "test_helper"

class TestRetryPolicy < Minitest::Test
  def policy = Mistri::RetryPolicy.new(attempts: 3, base: 1.0, max_delay: 30.0)

  def test_transient_statuses_retry_and_permanent_ones_fail_fast
    [408, 429, 500, 502, 503, 504, 529].each do |status|
      assert policy.retryable?({ "status" => status }), "expected #{status} to retry"
    end
    [400, 401, 403, 404, 422].each do |status|
      refute policy.retryable?({ "status" => status }), "expected #{status} to fail fast"
    end
  end

  def test_statusless_failures_retry_only_for_known_transient_types
    %w[ProviderError RateLimitError OverloadedError ServerError TruncatedStream].each do |type|
      assert policy.retryable?({ "type" => type })
    end
    %w[SchemaError RuntimeError Error NoMethodError].each do |type|
      refute policy.retryable?({ "type" => type })
    end
    refute policy.retryable?(nil)
  end

  def test_attempts_bound_the_retries
    error = { "status" => 529 }

    assert policy.retry?(error, 3)
    refute policy.retry?(error, 4)
  end

  def test_delay_honors_retry_after_and_caps_backoff
    assert_in_delta 7.0, policy.delay(1, 7.0)
    assert_in_delta 30.0, policy.delay(1, 600.0), 0.001, "retry_after clamps to max_delay"

    delay = policy.delay(3)

    assert_operator delay, :>=, 2.0, "attempt 3 backs off at least half of base * 2**2"
    assert_operator delay, :<=, 4.0
  end

  def test_error_data_captures_class_status_and_retry_after
    rate = Mistri::RateLimitError.new("slow down", status: 429, retry_after: 12.5)

    assert_equal({ "type" => "RateLimitError", "status" => 429, "retry_after" => 12.5 },
                 Mistri::ErrorData.for(rate))
    assert_equal({ "type" => "ServerError", "status" => 500 },
                 Mistri::ErrorData.for(Mistri::ServerError.new("boom", status: 500)))
    assert_equal({ "type" => "RuntimeError" }, Mistri::ErrorData.for(RuntimeError.new("x")))
    assert_equal({ "type" => "TruncatedStream" },
                 Mistri::ErrorData.for("stream ended without message_stop"))
  end
end
