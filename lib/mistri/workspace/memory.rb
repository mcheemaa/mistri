# frozen_string_literal: true

module Mistri
  # The document store agents work in. A workspace maps paths to text and can
  # live anywhere: memory for tests and ephemeral runs, a directory when disk
  # exists, the host's database when it does not. The file tools bind to this
  # port, so fuzzy-editing a MySQL row works exactly like editing a file.
  #
  # A backend implements read(path) -> String or nil, write(path, content),
  # delete(path), and list(prefix = nil) -> [paths].
  module Workspace
    class Memory
      def initialize
        @documents = {}
        @mutex = Mutex.new
      end

      def read(path)
        @mutex.synchronize { @documents[path.to_s] }
      end

      def write(path, content)
        @mutex.synchronize { @documents[path.to_s] = content.to_s.dup.freeze }
        nil
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
    end
  end
end
