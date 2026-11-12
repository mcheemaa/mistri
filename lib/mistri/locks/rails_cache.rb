# frozen_string_literal: true

# Opt-in, exactly like Stores::ActiveRecord: the gem never requires Rails.
# require "mistri/locks/rails_cache".
module Mistri
  module Locks
    # Leases and flags over an ActiveSupport::Cache::Store (Redis-backed in
    # any real deployment), so every process in the fleet reads the same
    # truth. Pass any cache store duck; defaults to Rails.cache.
    class RailsCache
      def initialize(cache: nil, namespace: "mistri:locks")
        @cache = cache || (defined?(Rails) && Rails.cache) ||
                 raise(ConfigurationError, "no cache store; pass cache: or configure Rails.cache")
        @namespace = namespace
      end

      # False means held. Rails 7.0 and 7.1 also answer false when the backend is down.
      def acquire(key, ttl:)
        written = @cache.write(scoped(key), true, unless_exist: true, expires_in: ttl)
        written.nil? ? failed(key) : written
      end

      def renew(key, ttl:)
        write(key, ttl)
        nil
      end

      def release(key)
        @cache.delete(scoped(key))
        nil
      end

      def held?(key)
        return true if @cache.exist?(scoped(key))

        # A miss and an outage read alike, so confirm the cache answers and read again.
        @cache.write("#{@namespace}-probe", true, expires_in: 60) ||
          raise(Error, "lock cache unreachable reading #{scoped(key)}")
        @cache.exist?(scoped(key))
      end

      def set_flag(key, ttl: 300)
        renew(key, ttl: ttl)
      end

      # Unprobed: the holder polls again within a second.
      def flag?(key) = @cache.exist?(scoped(key))

      def clear_flag(key) = release(key)

      private

      # Nothing contends for a plain write, so a falsy answer is a failed one.
      def write(key, ttl)
        @cache.write(scoped(key), true, expires_in: ttl) || failed(key)
      end

      def failed(key) = raise(Error, "lock cache write failed for #{scoped(key)}")

      def scoped(key) = "#{@namespace}:#{key}"
    end
  end
end
