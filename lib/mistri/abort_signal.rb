# frozen_string_literal: true

module Mistri
  # A thread-safe, one-way latch for cancelling a run. The host trips it from
  # any thread; the loop and tools check it cooperatively at safe points, and
  # the transport registers an on-abort callback to close an in-flight socket,
  # so even a stalled read stops immediately instead of waiting out its
  # read timeout.
  class AbortSignal
    def initialize
      @mutex = Mutex.new
      @aborted = false
      @reason = nil
      @callbacks = []
    end

    def aborted? = @aborted

    attr_reader :reason

    # Trip the latch and fire every registered callback exactly once.
    # Subsequent calls are no-ops.
    def abort!(reason = nil)
      callbacks = @mutex.synchronize do
        break [] if @aborted

        @aborted = true
        @reason = reason
        @callbacks.dup.tap { @callbacks.clear }
      end
      callbacks.each { |callback| safely(callback) }
      nil
    end

    # A signal that trips when this one does, never the reverse: abort the
    # derived signal alone and this one runs on. Returns [signal, handle];
    # remove the handle when the derived work ends, so a finished child
    # never leaks a callback into a later abort.
    def derive
      child = AbortSignal.new
      handle = on_abort { child.abort!(reason) }
      [child, handle]
    end

    # Register a callback for the moment of abort. Fires immediately when the
    # signal is already tripped. Returns a handle for #remove_callback.
    def on_abort(&callback)
      fire_now = @mutex.synchronize do
        @callbacks << callback unless @aborted
        @aborted
      end
      safely(callback) if fire_now
      callback
    end

    # Deregister a callback, so a completed request does not leak its socket
    # closer into a later abort.
    def remove_callback(handle)
      @mutex.synchronize { @callbacks.delete(handle) }
      nil
    end

    private

    # An abort must reach every callback; one raising observer cannot be
    # allowed to strand the others.
    def safely(callback)
      callback.call
    rescue StandardError
      nil
    end
  end
end
