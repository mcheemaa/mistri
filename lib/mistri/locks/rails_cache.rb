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

      def acquire(key, ttl:)
        @cache.write(scoped(key), true, unless_exist: true, expires_in: ttl)
      end

      def renew(key, ttl:)
        @cache.write(scoped(key), true, expires_in: ttl)
        nil
      end

      def release(key)
        @cache.delete(scoped(key))
        nil
      end

      def held?(key)
        @cache.exist?(scoped(key))
      end

      def set_flag(key, ttl: 300)
        renew(key, ttl: ttl)
      end

      def flag?(key) = held?(key)

      def clear_flag(key) = release(key)

      private

      def scoped(key) = "#{@namespace}:#{key}"
    end
  end
end
