# frozen_string_literal: true

module Mistri
  class Session
    # A session's entries as read so far. The log only grows and a committed
    # entry never changes, so each read asks the store for what came after the
    # entries already held. The held entries are frozen: every reader of one
    # Session shares them, from any thread.
    class Log
      def initialize(store, id)
        @store = store
        @id = id
        @entries = [].freeze
        @mutex = Mutex.new
      end

      def entries
        @mutex.synchronize do
          appended = @store.load(@id, from: @entries.length).each { |entry| deep_freeze(entry) }
          next @entries if appended.empty?

          entries = (@entries + appended).freeze
          @entries = entries unless in_transaction?
          entries
        end
      end

      private

      # Rows read inside an open transaction can still be rolled back. They
      # are answered and read again next time, never held.
      def in_transaction?
        @store.respond_to?(:in_transaction?) && @store.in_transaction?
      end

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
