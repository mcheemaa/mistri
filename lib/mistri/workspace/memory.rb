# frozen_string_literal: true

require_relative "../workspace"

module Mistri
  module Workspace
    # A mutex-protected ephemeral document map with atomic conditional writes.
    class Memory
      def initialize
        @documents = {}
        @mutex = Mutex.new
      end

      def read(path)
        @mutex.synchronize { @documents[path.to_s]&.dup }
      end

      def write(path, content)
        @mutex.synchronize { @documents[path.to_s] = own(content) }
        nil
      end

      def atomic_writes? = true

      def snapshot(path)
        @mutex.synchronize do
          content = @documents[path.to_s]
          content && Snapshot.for(content)
        end
      end

      def compare_and_write(path, content, expected_revision:)
        @mutex.synchronize do
          key = path.to_s
          current = @documents[key]
          actual = current && Snapshot.for(current).revision
          unless actual == expected_revision
            raise WorkspaceConflictError.new(
              key, expected_revision:, actual_revision: actual
            )
          end

          @documents[key] = own(content)
          Snapshot.for(@documents[key])
        end
      end

      def delete(path)
        @mutex.synchronize { @documents.delete(path.to_s) }
        nil
      end

      def list(prefix = nil)
        @mutex.synchronize do
          keys = @documents.keys.sort
          prefix ? keys.select { |key| key.start_with?(prefix.to_s) } : keys
        end
      end

      private

      def own(content) = String.new(content.to_s).freeze
    end
  end
end
