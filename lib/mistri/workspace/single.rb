# frozen_string_literal: true

module Mistri
  module Workspace
    # One document living wherever the host says: a column on a record, a
    # cache key, anything readable and writable. This is the shape of an
    # agent that edits one page:
    #
    #   workspace = Mistri::Workspace::Single.new(
    #     path: "page.html",
    #     read: -> { page.reload.draft_html },
    #     write: ->(html) { page.update!(draft_html: html) }
    #   )
    #
    # The document tools then read and edit that column like any document.
    class Single
      def initialize(read:, write:, path: "document")
        @path = path.to_s
        @read = read
        @write = write
      end

      def read(path)
        path.to_s == @path ? @read.call : nil
      end

      def write(path, content)
        raise SchemaError, "this workspace holds only #{@path.inspect}" unless path.to_s == @path

        @write.call(content.to_s)
        nil
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
    end
  end
end
