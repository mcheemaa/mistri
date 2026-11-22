# frozen_string_literal: true

module Mistri
  module Tools
    MAX_LISTED = 200

    module_function

    def list_files(workspace)
      Tool.define("list_files",
                  "List documents with their sizes, optionally under a prefix.",
                  save_result: false,
                  schema: -> { string :prefix, "Only paths starting with this" }) do |args|
        prefix = args["prefix"].to_s
        next listing(workspace, nil) if prefix.empty?

        unusable_path(prefix, prefix: true) || listing(workspace, prefix)
      end
    end

    # Sizes come from a workspace that answers sizes, so a listing never
    # reads a document to measure it.
    def listing(workspace, prefix)
      lines = if workspace.respond_to?(:sizes)
                workspace.sizes(prefix).map { |path, bytes| "#{path} (#{bytes} bytes)" }
              else
                workspace.list(prefix)
              end
      return "No documents found." if lines.empty?

      more = lines.length - MAX_LISTED
      rest = more.positive? ? "\n[#{more} more not shown. Pass a prefix to narrow.]" : ""
      "#{lines.first(MAX_LISTED).join("\n")}#{rest}"
    end
  end
end
