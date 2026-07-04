# frozen_string_literal: true

module Mistri
  module Tools
    module_function

    def list_files(workspace)
      Tool.define("list_files",
                  "List document paths in the workspace, optionally under a prefix.",
                  schema: -> { string :prefix, "Only paths starting with this" }) do |args|
        paths = workspace.list(args["prefix"])
        paths.empty? ? "No documents found." : paths.join("\n")
      end
    end
  end
end
