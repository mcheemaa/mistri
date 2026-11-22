# frozen_string_literal: true

module Mistri
  module Tools
    module_function

    def delete_file(workspace)
      Tool.define("delete_file", "Delete a document.",
                  schema: -> { string :path, "Document path", required: true }) do |args|
        with_document(workspace, args) do
          workspace.delete(args["path"])
          "Deleted #{args["path"]}"
        end
      end
    end
  end
end
