# frozen_string_literal: true

module Mistri
  # Root of every error Mistri raises, so a host can rescue Mistri::Error.
  #
  # Only failures the model cannot recover from raise: configuration, transport,
  # budgets, aborts. A tool that fails during a run becomes an in-band tool
  # result the model can react to, never an exception out of the loop.
  class Error < StandardError; end

  # Missing or contradictory setup: an unknown model, an absent API key.
  class ConfigurationError < Error; end

  # A provider request failed. Carries the HTTP status and response body when
  # the transport got that far.
  class ProviderError < Error
    attr_reader :status, :body

    def initialize(message = nil, status: nil, body: nil)
      @status = status
      @body = body
      super(message || self.class.default_message)
    end

    def self.default_message = "provider request failed"
  end

  class AuthenticationError < ProviderError
    def self.default_message = "invalid or missing API key"
  end

  class RateLimitError < ProviderError
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil, **)
      @retry_after = retry_after
      super(message, **)
    end

    def self.default_message = "rate limited"
  end

  class OverloadedError < ProviderError
    def self.default_message = "provider overloaded"
  end

  class ServerError < ProviderError
    def self.default_message = "provider server error"
  end

  # Tool arguments or structured output that violate their declared schema.
  class SchemaError < Error; end

  # A run cancelled by the host, raised only when the caller opts into raising.
  class AbortError < Error; end

  # A run stopped by its turn, token, cost, or wall-clock budget.
  class BudgetError < Error; end
end
