# frozen_string_literal: true

module Mistri
  class Session
    # A session's entries as read so far. The log only grows and a committed
    # entry never changes, so a read asks the store for what came after the
    # entries already held. That holds only while the store says its reads are
    # settled. A store that does not say so, or says no, is read whole and
    # nothing is held. The entries are frozen: every reader of one Session
    # shares them, from any thread.
    class Log
      attr_reader :id

      # The id is the caller's object and a String can be changed in place.
      # The log reads under its own copy, so its entries stay one session's.
      def initialize(store, id)
        @store = store
        @id = id.frozen? ? id : id.dup.freeze
        @entries = [].freeze
        @mutex = Mutex.new
      end

      def entries
        return frozen(@store.load(@id)).freeze unless settled?

        @mutex.synchronize do
          appended = frozen(@store.load(@id, from: @entries.length))
          @entries = (@entries + appended).freeze unless appended.empty?
          @entries
        end
      end

      private

      def settled? = @store.respond_to?(:settled?) && @store.settled?

      def frozen(entries) = entries.each { |entry| deep_freeze(entry) }

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |nested| deep_freeze(nested) }
        when Array then value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end
    end
  end
end
