# frozen_string_literal: true

module Mistri
  module Tools
    StaleWrite = Data.define(:current)
    private_constant :StaleWrite

    module_function

    def write_file(workspace)
      atomic = atomic_workspace?(workspace)
      tool = Tool.define("write_file",
                         "Create a document, or replace one. To replace a document that exists, " \
                         "pass if_version, the version read_file showed for it. A write without " \
                         "the current version is refused and returns the document as it is now.",
                         eager_input_streaming: true, save_result: false,
                         schema: lambda {
                           string :path, "Document path", required: true
                           string :content, "The full document content", required: true
                           string :if_version, "The version of the document this replaces"
                         }) do |args, context|
        path = args["path"]
        refusal = unusable_path(path) || read_only(path)
        next refusal if refusal

        content = args["content"].to_s
        written = if atomic
                    write_atomically(workspace, path, content, args["if_version"])
                  else
                    write_legacy(workspace, path, content, args["if_version"])
                  end
        if written.is_a?(StaleWrite)
          next stale_write(path, written.current, args["if_version"], window_bytes(context))
        end

        "Wrote #{path} (#{written.length} chars), version #{version(written)}"
      end
      bind(workspace, tool)
    end

    def write_legacy(workspace, path, content, if_version)
      current = workspace.read(path)
      return StaleWrite.new(current) if current && version(current) != if_version

      workspace.write(path, content)
      content
    end

    # A workspace that cannot make the check and the write one step where it
    # is called, as the Active Record one inside a transaction the host
    # opened, gets them as two.
    def write_atomically(workspace, path, content, if_version)
      snapshot = workspace.snapshot(path)
      return StaleWrite.new(snapshot.content) if snapshot && version(snapshot.content) != if_version

      workspace.compare_and_write(path, content, expected_revision: snapshot&.revision).content
    rescue WorkspaceConflictError
      StaleWrite.new(workspace.read(path).to_s)
    rescue ConfigurationError
      write_legacy(workspace, path, content, if_version)
    end

    def stale_write(path, current, if_version, bytes)
      reason = if if_version
                 "#{path} is not at version #{if_version} any more"
               else
                 "#{path} holds a document already"
               end
      ToolResult.new(
        content: "write_file refused: #{reason}. Nothing was written. To replace it, pass " \
                 "its version as if_version. To change part of it, use edit_file. The " \
                 "document now:\n#{window(path, current, bytes: bytes - WINDOW_MARGIN_BYTES)}",
        error: true
      )
    end
  end
end
