# frozen_string_literal: true

require_relative "../workspace"

module Mistri
  module Workspace
    # One document living wherever the host says: a column on a record, a
    # cache key, anything readable and writable. This is the shape of an
    # agent that edits one page:
    #
    #   workspace = Mistri::Workspace::Single.new(
    #     path: "page.html",
    #     read: -> { page.reload.draft_html },
    #     write: ->(html) { page.update!(draft_html: html) },
    #     synchronize: lambda do |&operation|
    #       raise "outer transaction" if page.class.connection.transaction_open?
    #       page.with_lock(&operation)
    #     end
    #   )
    #
    # The document tools then read and edit that column like any document.
    # synchronize: is optional; without it, the legacy read/write port cannot
    # protect an edit from another process writing between those two calls.
    class Single
      def initialize(read:, write:, path: "document", synchronize: nil)
        unless synchronize.nil? || synchronize.respond_to?(:call)
          raise ArgumentError, "synchronize must be callable"
        end

        @path = String.new(path.to_s).freeze
        @read = read
        @write = write
        @synchronize = synchronize
      end

      def read(path)
        path.to_s == @path ? @read.call : nil
      end

      def write(path, content)
        verify_path!(path)

        synchronize { @write.call(content.to_s) }
        nil
      end

      def atomic_writes? = !@synchronize.nil?

      def snapshot(path)
        return nil unless path.to_s == @path

        content = @read.call
        content.nil? ? nil : Snapshot.for(content.to_s)
      end

      def compare_and_write(path, content, expected_revision:)
        verify_path!(path)
        unless atomic_writes?
          raise ConfigurationError, "Single needs synchronize: for atomic writes"
        end

        synchronize do
          current = @read.call
          actual = current.nil? ? nil : Snapshot.for(current.to_s).revision
          unless actual == expected_revision
            raise WorkspaceConflictError.new(
              @path, expected_revision:, actual_revision: actual
            )
          end

          @write.call(content.to_s)
          committed = @read.call
          raise SchemaError, "#{@path.inspect} disappeared after write" if committed.nil?

          Snapshot.for(committed.to_s)
        end
      end

      def delete(path)
        if path.to_s == @path
          raise SchemaError,
                "#{@path.inspect} cannot be deleted, only rewritten"
        end

        nil
      end

      def list(prefix = nil)
        prefix.nil? || @path.start_with?(prefix.to_s) ? [@path] : []
      end

      private

      def verify_path!(path)
        return if path.to_s == @path

        raise SchemaError, "this workspace holds only #{@path.inspect}"
      end

      def synchronize(&operation)
        @synchronize ? @synchronize.call(&operation) : operation.call
      end
    end
  end
end
