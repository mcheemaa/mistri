# frozen_string_literal: true

module Mistri
  # Built-in tools. Tools.files binds the document tools to a workspace, so
  # "file" means whatever the workspace says it means: a database column, a
  # row in a documents table, or an actual file. The names stay read_file and
  # edit_file because those are the tool names models are trained on.
  module Tools
    ALIASES = { "oldText" => "old_string", "old" => "old_string", "search" => "old_string",
                "newText" => "new_string", "new" => "new_string", "replace" => "new_string",
                "replaceAll" => "replace_all", "file" => "path", "filename" => "path" }.freeze

    module_function

    def files(workspace)
      [read_file(workspace), write_file(workspace), edit_file(workspace),
       find_in_file(workspace), list_files(workspace)]
    end

    def with_document(workspace, args)
      content = workspace.read(args["path"])
      return "No document at #{args["path"].inspect}. Use list_files to see paths." if content.nil?

      yield content
    end

    # Absorb the drift real models produce: alias keys, stringly booleans,
    # unknown keys dropped by simply never being read.
    def tolerate(args)
      normalized = args.to_h { |key, value| [ALIASES.fetch(key.to_s, key.to_s), value] }
      case normalized["replace_all"]
      when "true", "1", 1 then normalized["replace_all"] = true
      when "false", "0", 0, nil then normalized["replace_all"] = false
      end
      normalized
    end
  end
end

require_relative "tools/read_file"
require_relative "tools/write_file"
require_relative "tools/edit_file"
require_relative "tools/find_in_file"
require_relative "tools/list_files"
