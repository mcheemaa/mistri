# frozen_string_literal: true

module Mistri
  module Tools
    module_function

    def delete_file(workspace)
      tool = Tool.define("delete_file", "Delete a document.",
                         save_result: false,
                         schema: -> { string :path, "Document path", required: true }) do |args|
        refusal = unusable_path(args["path"]) || read_only(args["path"])
        next refusal if refusal

        with_document(workspace, args) do
          workspace.delete(args["path"])
          "Deleted #{args["path"]}"
        end
      end
      bind(workspace, tool)
    end
  end
end
