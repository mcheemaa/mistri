# frozen_string_literal: true

module Mistri
  module Test
    # The four methods a workspace must have and nothing more: no sizes and
    # no conditional write.
    class PlainWorkspace
      def initialize = @documents = {}
      def read(path) = @documents[path]
      def write(path, content) = @documents[path] = content
      def delete(path) = @documents.delete(path)

      def list(prefix = nil)
        @documents.keys.select { |path| prefix.nil? || path.start_with?(prefix) }.sort
      end
    end
  end
end
