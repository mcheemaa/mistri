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
        @mutex.synchronize { @entries[id] << json_copy(entry, freeze: true) }
        nil
      end

      def load(id)
        @mutex.synchronize do
          @entries[id].map { |entry| json_copy(entry, freeze: false) }
        end
      end

      private

      # Memory must preserve the same value ownership as stores that decode
      # every read; otherwise a transcript reader can rewrite durable history.
      def json_copy(value, freeze:)
        owned = case value
                when Hash
                  value.to_h do |key, nested|
                    [json_copy(key, freeze:), json_copy(nested, freeze:)]
                  end
                when Array then value.map { |nested| json_copy(nested, freeze:) }
                when String then value.dup
                else value
                end
        freeze ? owned.freeze : owned
      end
    end
  end
end
