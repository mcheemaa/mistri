# frozen_string_literal: true

require_relative "test_helper"

class TestErrors < Minitest::Test
  def test_every_error_rescues_as_mistri_error
    [Mistri::ConfigurationError, Mistri::ProviderError, Mistri::AuthenticationError,
     Mistri::RateLimitError, Mistri::OverloadedError, Mistri::ServerError,
     Mistri::AmbiguousDeliveryError, Mistri::InvalidRequestError, Mistri::SchemaError,
     Mistri::AbortError, Mistri::BudgetError].each do |klass|
      assert_operator klass, :<, Mistri::Error
    end
  end

  def test_provider_error_carries_the_response
    error = Mistri::ServerError.new(status: 503, body: "upstream connect error")

    assert_equal 503, error.status
    assert_equal "upstream connect error", error.body
    assert_equal "provider server error", error.message
  end

  def test_rate_limit_error_carries_retry_after
    error = Mistri::RateLimitError.new(retry_after: 12.5, status: 429)

    assert_in_delta 12.5, error.retry_after
    assert_equal 429, error.status
  end

  def test_ambiguous_delivery_error_warns_against_an_automatic_retry
    error = Mistri::AmbiguousDeliveryError.new

    assert_match(/operation may have completed/, error.message)
    assert_match(/do not retry automatically/, error.message)
  end
end
