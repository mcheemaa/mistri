# frozen_string_literal: true

module Mistri
  module Tools
    MAX_LISTED = 200

    module_function

    def list_files(workspace)
      tool = Tool.define("list_files",
                         "List documents with their sizes, optionally under a prefix.",
                         save_result: false,
                         schema: lambda {
                           string :prefix, "Only paths starting with this"
                         }) do |args, context|
        prefix = args["prefix"].to_s
        bytes = window_bytes(context)
        next listing(workspace, nil, bytes) if prefix.empty?

        unusable_path(prefix, prefix: true) || listing(workspace, prefix, bytes)
      end
      bind(workspace, tool)
    end

    # Sizes come from a workspace that answers sizes, so a listing never
    # reads a document to measure it.
    def listing(workspace, prefix, bytes = MAX_READ_BYTES)
      lines = if workspace.respond_to?(:sizes)
                workspace.sizes(prefix).map { |path, size| "#{path} (#{size} bytes)" }
              else
                workspace.list(prefix)
              end
      return "No documents found." if lines.empty?

      shown = listed(lines, bytes)
      more = lines.length - shown.length
      rest = more.positive? ? "\n[#{more} more not shown. Pass a prefix to narrow.]" : ""
      "#{shown.join("\n")}#{rest}"
    end

    def listed(lines, bytes)
      size = 0
      lines.first(MAX_LISTED).take_while.with_index do |line, index|
        size += line.bytesize + 1
        index.zero? || size <= bytes
      end
    end
  end
end
