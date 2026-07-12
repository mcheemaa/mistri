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

  # A queue payload is not the grant persisted for its child. The unchanged
  # delivery is poison: discard and alert instead of retrying it.
  class DispatchGrantError < ConfigurationError; end

  # A provider request failed. Carries the HTTP status and response body when
  # the transport got that far.
  class ProviderError < Error
    attr_reader :status, :body

    def initialize(message = nil, status: nil, body: nil)
      @status = status
      @body = body
      super(message || self.class.default_message)
    end

    # The full story for logs and error turns: the response names the fix far
    # more often than the status line does.
    def describe
      parts = [message]
      parts << "status #{status}" if status
      parts << body.to_s[0, 300] if body && !body.to_s.strip.empty?
      parts.join(" | ")
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

  # An inbound body or protocol record crossed its configured byte boundary.
  class ResponseTooLargeError < Error
    attr_reader :kind, :limit

    def initialize(kind:, limit:)
      @kind = kind
      @limit = limit
      label = kind.to_s.tr("_", " ")
      super("#{label} exceeded the byte limit (#{limit} bytes)")
    end
  end

  # A JSON protocol record crossed a structural boundary before parsing.
  class ResponseTooComplexError < Error
    attr_reader :kind, :limit

    def initialize(kind:, limit:)
      @kind = kind
      @limit = limit
      label = kind.to_s.tr("_", " ")
      super("#{label} exceeded the complexity limit (#{limit})")
    end
  end

  # A non-replayable request has no confirmed response, so execution is unknown.
  class AmbiguousDeliveryError < ProviderError
    def self.default_message
      "connection failed before the response was confirmed; the operation may have completed; " \
        "do not retry automatically; verify external state first"
    end
  end

  # The provider rejected the request itself: an invalid prompt, a bad
  # image, a policy violation. Never retried; the same input cannot succeed.
  class InvalidRequestError < ProviderError
    def self.default_message = "provider rejected the request"
  end

  # Tool arguments or structured output that violate their declared schema.
  class SchemaError < Error; end

  # A run cancelled by the host, raised only when the caller opts into raising.
  class AbortError < Error; end

  # A cost-budgeted request returned without trustworthy accounting. Usage and
  # provider_message preserve the uncertain attempt for host reconciliation.
  class BudgetError < Error
    attr_reader :usage, :provider_message

    def initialize(message = nil, usage: nil, provider_message: nil)
      @usage = usage
      @provider_message = provider_message
      super(message)
    end
  end

  # A text edit that did not match uniquely, or overlapped another edit.
  class EditError < Error; end

  # Compaction could not produce a usable summary. Usage preserves any billed
  # provider attempt even though no checkpoint was written.
  class CompactionError < Error
    attr_reader :usage

    def initialize(message = nil, usage: nil)
      @usage = usage
      super(message)
    end
  end

  # The machine-readable shape of a stream failure, carried on errored
  # assistant messages so retry policies and hosts can classify without
  # parsing prose. Strings are the assemblers' synthesized truncation
  # reasons.
  module ErrorData
    module_function

    def for(reason)
      case reason
      when RateLimitError
        { "type" => "RateLimitError", "status" => reason.status,
          "retry_after" => reason.retry_after }.compact
      when ResponseTooLargeError
        { "type" => "ResponseTooLargeError", "kind" => reason.kind.to_s,
          "limit" => reason.limit }
      when ResponseTooComplexError
        { "type" => "ResponseTooComplexError", "kind" => reason.kind.to_s,
          "limit" => reason.limit }
      when ProviderError
        { "type" => reason.class.name.split("::").last, "status" => reason.status }.compact
      when Exception then { "type" => reason.class.name }
      else { "type" => "TruncatedStream" }
      end
    end
  end
end
