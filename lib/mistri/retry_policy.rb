# frozen_string_literal: true

module Mistri
  # When a failed turn is worth retrying, and how long to wait. Transient
  # failures (rate limits, overload, server errors, timeouts, dropped or
  # truncated streams) retry with jittered exponential backoff, honoring the
  # provider's retry-after when it sent one. Everything else — auth, invalid
  # requests, our own bugs — fails fast.
  #
  # attempts counts retries, not calls: attempts 3 means up to four requests.
  class RetryPolicy
    RETRYABLE_STATUSES = [408, 429, 500, 502, 503, 504, 529].freeze
    RETRYABLE_TYPES = %w[ProviderError RateLimitError OverloadedError ServerError
                         TruncatedStream EmptyCompletion].freeze

    attr_reader :attempts, :base, :max_delay

    def initialize(attempts: 3, base: 1.0, max_delay: 30.0)
      @attempts = attempts
      @base = base
      @max_delay = max_delay
    end

    def retry?(error, attempt)
      attempt <= attempts && retryable?(error)
    end

    # error is the ErrorData hash from an errored message. A status decides
    # when present; otherwise only known-transient types retry, so schema
    # violations and host bugs never loop.
    def retryable?(error)
      return false unless error

      status = error["status"]
      return RETRYABLE_STATUSES.include?(status) if status

      RETRYABLE_TYPES.include?(error["type"])
    end

    def delay(attempt, retry_after = nil)
      return retry_after.clamp(0.0, max_delay) if retry_after

      exponential = base * (2**(attempt - 1))
      (exponential * rand(0.5..1.0)).clamp(0.0, max_delay)
    end
  end
end
