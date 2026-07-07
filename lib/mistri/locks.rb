# frozen_string_literal: true

require "monitor"

module Mistri
  # Cross-process coordination for hosts that run loops in more than one
  # process: leases that say "this is alive right now" and flags that carry
  # one-bit requests (stop) between processes. Everything expires on its
  # own, so a crashed holder never wedges anything; a live holder renews on
  # a heartbeat, so only dead ones expire.
  #
  # Configure once at boot:
  #
  #   Mistri.locks = Mistri::Locks::Memory.new          # single process
  #   Mistri.locks = Mistri::Locks::RailsCache.new      # requires opt-in file
  #
  # An adapter implements six methods: acquire(key, ttl:) -> bool,
  # renew(key, ttl:), release(key), held?(key), set_flag(key, ttl:),
  # flag?(key), clear_flag(key). With no adapter configured, everything
  # lease-aware degrades gracefully: children read :running instead of
  # :interrupted, and holds are no-ops.
  module Locks
    LEASE_TTL = 180
    HEARTBEAT = 60

    module_function

    # Hold a lease for the duration of a block of work: acquire, renew on a
    # heartbeat from a background thread, release on the way out. Returns a
    # Hold, or nil when no adapter is configured; call #release in an ensure.
    def hold(key, ttl: LEASE_TTL, heartbeat: HEARTBEAT)
      adapter = Mistri.locks
      return nil unless adapter

      adapter.acquire(key, ttl: ttl)
      Hold.new(adapter, key, ttl, heartbeat)
    end

    # A held lease: a renewal thread keeps it alive, release stops the
    # thread (and joins it, so a mid-renewal tick can never re-stamp a
    # lease that was just released) and deletes the key.
    class Hold
      def initialize(adapter, key, ttl, heartbeat)
        @adapter = adapter
        @key = key
        @stopping = false
        @thread = Thread.new do
          until @stopping
            sleep heartbeat
            @adapter.renew(key, ttl: ttl) unless @stopping
          end
        end
      end

      def release
        @stopping = true
        @thread.kill
        @thread.join(2)
        @adapter.release(@key)
      end
    end

    # The in-process adapter: real TTL semantics over a hash, for tests,
    # development, and the thread dispatcher. Monitor-synchronized; expiry
    # is judged at read time, so nothing needs a sweeper.
    class Memory
      def initialize
        @entries = {}
        @lock = Monitor.new
      end

      def acquire(key, ttl:)
        @lock.synchronize do
          return false if live?(key)

          @entries[key] = deadline(ttl)
          true
        end
      end

      def renew(key, ttl:)
        @lock.synchronize { @entries[key] = deadline(ttl) }
        nil
      end

      def release(key)
        @lock.synchronize { @entries.delete(key) }
        nil
      end

      def held?(key)
        @lock.synchronize { live?(key) }
      end

      def set_flag(key, ttl: 300)
        renew(key, ttl: ttl)
      end

      def flag?(key) = held?(key)

      def clear_flag(key) = release(key)

      private

      def live?(key)
        deadline = @entries[key]
        return false unless deadline
        return true if deadline > now

        @entries.delete(key)
        false
      end

      def deadline(ttl) = now + ttl

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
