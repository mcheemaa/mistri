# frozen_string_literal: true

module Mistri
  module Tools
    MAX_ATOMIC_EDIT_ATTEMPTS = 3
    private_constant :MAX_ATOMIC_EDIT_ATTEMPTS

    module_function

    # The model-facing shape is flat {path, old_string, new_string,
    # replace_all} on purpose: it is the shape frontier models are trained on,
    # and nested edit arrays measurably degrade their calls. Failures come
    # back in band with the closest region and its exact difference, so the
    # model's retry is one shot.
    def edit_file(workspace)
      atomic = atomic_workspace?(workspace)
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
        result = if atomic
                   replace_atomically(workspace, args)
                 else
                   replace_legacy(workspace, args)
                 end
        next result if result.is_a?(ToolResult)

        "Replaced #{result.count} occurrence(s) in #{args["path"]}"
      rescue EditError, WorkspaceConflictError => e
        ToolResult.new(content: "edit_file failed: #{e.message}", error: true)
      end
    end

    def replace_legacy(workspace, args)
      with_document(workspace, args) do |content|
        result = replacement(content, args)
        workspace.write(args["path"], result.content)
        result
      end
    end

    def replace_atomically(workspace, args)
      MAX_ATOMIC_EDIT_ATTEMPTS.times do |attempt|
        snapshot = workspace.snapshot(args["path"])
        return missing_document(args["path"]) unless snapshot
        unless snapshot.is_a?(Workspace::Snapshot)
          raise TypeError, "workspace snapshot must be a Mistri::Workspace::Snapshot"
        end

        result = replacement(snapshot.content, args)
        begin
          committed = workspace.compare_and_write(
            args["path"], result.content, expected_revision: snapshot.revision
          )
          unless committed.is_a?(Workspace::Snapshot)
            raise TypeError,
                  "workspace compare_and_write must return a Mistri::Workspace::Snapshot"
          end
          unless same_content_bytes?(committed.content, result.content)
            return ToolResult.new(
              content: "The write to #{args["path"].inspect} committed, but storage " \
                       "transformed the resulting document. Use read_file before continuing.",
              error: true
            )
          end
          return result
        rescue WorkspaceConflictError
          raise if attempt == MAX_ATOMIC_EDIT_ATTEMPTS - 1
        end
      end
    end

    def replacement(content, args)
      Edit.replace(content, args["old_string"], args["new_string"],
                   replace_all: args["replace_all"] == true)
    end

    def same_content_bytes?(left, right)
      left == right || (left.bytesize == right.bytesize && left.b == right.b)
    end
  end
end
