# frozen_string_literal: true

module Mistri
  class Session
    # A session's entries as read so far. The log only grows and an entry
    # never changes once appended, so each read asks the store for what came
    # after the entries already held. The held entries are frozen: every
    # reader of one Session shares them, from any thread.
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
          @entries = (@entries + appended).freeze unless appended.empty?
          @entries
        end
      end

      private

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
