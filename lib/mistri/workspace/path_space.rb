# frozen_string_literal: true

require_relative "../workspace"

module Mistri
  module Workspace
    # A host's documents and an agent's scratchpad as one workspace: a path
    # under scratchpad/ belongs to the scratchpad's workspace and every other
    # path to the host's. Paths are passed on as they are, so the two may be
    # the same workspace.
    class PathSpace
      # Sizes in one listing, where both workspaces answer them.
      module Sizes
        def sizes(prefix = nil)
          @files.sizes(prefix).reject { |path, _bytes| scratch?(path) }
                .merge(@scratchpad.sizes(prefix).select { |path, _bytes| scratch?(path) })
                .sort.to_h
        end
      end
      private_constant :Sizes

      def initialize(files:, scratchpad:)
        @files = files
        @scratchpad = scratchpad
        extend(Sizes) if [files, scratchpad].all? { |workspace| workspace.respond_to?(:sizes) }
      end

      def read(path) = home(path).read(path)

      def write(path, content) = home(path).write(path, content)

      def delete(path) = home(path).delete(path)

      def list(prefix = nil)
        (@files.list(prefix).reject { |path| scratch?(path) } +
          @scratchpad.list(prefix).select { |path| scratch?(path) }).sort
      end

      # Conditional writes hold only where both workspaces make them.
      def atomic_writes?
        [@files, @scratchpad].all? { |workspace| Tools.atomic_workspace?(workspace) }
      end

      def snapshot(path) = home(path).snapshot(path)

      def compare_and_write(path, content, expected_revision:)
        home(path).compare_and_write(path, content, expected_revision:)
      end

      private

      def home(path) = scratch?(path) ? @scratchpad : @files

      def scratch?(path) = path.to_s.start_with?(Scratchpad::ROOT)
    end
  end
end
