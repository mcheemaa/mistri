# frozen_string_literal: true

module Mistri
  module Stores
    # Entries in a plain Hash: for tests and runs that need no persistence.
    class Memory
      def initialize
        @entries = Hash.new { |hash, key| hash[key] = [] }
        @mutex = Mutex.new
      end

      def append(id, entry)
        @mutex.synchronize { @entries[id] << entry }
        nil
      end

      def load(id)
        @mutex.synchronize { @entries[id].dup }
      end
    end
  end
end
