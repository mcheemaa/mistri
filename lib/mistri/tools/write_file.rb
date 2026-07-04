# frozen_string_literal: true

module Mistri
  module Tools
    module_function

    def write_file(workspace)
      Tool.define("write_file",
                  "Create or fully overwrite a document with the given content.",
                  eager_input_streaming: true,
                  schema: lambda {
                    string :path, "Document path", required: true
                    string :content, "The full document content", required: true
                  }) do |args|
        workspace.write(args["path"], args["content"])
        "Wrote #{args["path"]} (#{args["content"].to_s.length} chars)"
      end
    end
  end
end
