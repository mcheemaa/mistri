# frozen_string_literal: true

module Mistri
  module Tools
    module_function

    # The model-facing shape is flat {path, old_string, new_string,
    # replace_all} on purpose: it is the shape frontier models are trained on,
    # and nested edit arrays measurably degrade their calls. Failures come
    # back in band with the closest region and its exact difference, so the
    # model's retry is one shot.
    def edit_file(workspace)
      Tool.define("edit_file",
                  "Replace an exact snippet of a document. Copy old_string verbatim from " \
                  "read_file output including whitespace, without line-number prefixes. " \
                  "It must match exactly one place; add surrounding lines to make it " \
                  "unique, or set replace_all to change every occurrence.",
                  eager_input_streaming: true,
                  argument_normalizer: Tools.method(:tolerate),
                  schema: lambda {
                    string :path, "Document path", required: true
                    string :old_string, "Exact text to replace (whitespace matters)", required: true
                    string :new_string, "Replacement text", required: true
                    boolean :replace_all, "Replace every occurrence instead of exactly one"
                  }) do |args|
        with_document(workspace, args) do |content|
          result = Edit.replace(content, args["old_string"], args["new_string"],
                                replace_all: args["replace_all"] == true)
          workspace.write(args["path"], result.content)
          "Replaced #{result.count} occurrence(s) in #{args["path"]}"
        end
      rescue EditError => e
        "edit_file failed: #{e.message}"
      end
    end
  end
end
