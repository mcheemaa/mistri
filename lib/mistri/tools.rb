# frozen_string_literal: true

module Mistri
  # Built-in tools. Tools.files binds the document tools to a workspace, so
  # "file" means whatever the workspace says it means: a database column, a
  # row in a documents table, or an actual file. The names stay read_file and
  # edit_file because those are the tool names models are trained on.
  module Tools
    ATOMIC_WORKSPACE_METHODS = %i[snapshot compare_and_write].freeze
    private_constant :ATOMIC_WORKSPACE_METHODS
    MAX_PATH_BYTES = 512
    ALIASES = { "oldText" => "old_string", "old" => "old_string", "search" => "old_string",
                "newText" => "new_string", "new" => "new_string", "replace" => "new_string",
                "replaceAll" => "replace_all", "file" => "path", "filename" => "path" }.freeze

    module_function

    def files(workspace)
      [read_file(workspace), write_file(workspace), edit_file(workspace),
       grep(workspace), list_files(workspace), delete_file(workspace)]
    end

    def memory(store)
      [read_memory(store), update_memory(store)]
    end

    def with_document(workspace, args)
      unusable = unusable_path(args["path"])
      return unusable if unusable

      content = workspace.read(args["path"])
      return missing_document(args["path"]) if content.nil?

      yield content
    end

    # What read_file shows for a document and write_file takes back as
    # if_version: the same for the same bytes, in any process.
    def version(content)
      Digest::SHA256.hexdigest(content.b)[0, 12]
    end

    # A path from the model is checked before any workspace is asked, so the
    # same rules hold on every backend: relative, parts joined by /, and no
    # part that is empty, . or ..
    def unusable_path(path, prefix: false)
      path = path.to_s
      path = path.delete_suffix("/") if prefix
      problem = path_problem(path)
      return unless problem

      ToolResult.new(
        content: "#{path.inspect} is not a path here: #{problem}. Use a relative path such " \
                 "as notes/plan.md.",
        error: true
      )
    end

    def path_problem(path)
      return "it is empty" if path.empty?
      return "it is longer than #{MAX_PATH_BYTES} bytes" if path.bytesize > MAX_PATH_BYTES
      return "it is not valid UTF-8" unless path.valid_encoding?
      return "it holds a control character or a backslash" if path.match?(/[\x00-\x1f\x7f\\]/)
      return "it starts with /" if path.start_with?("/")

      parts = path.split("/", -1)
      "it holds an empty part, . or .." if parts.intersect?(["", ".", ".."])
    end

    # The folder an agent saves whole tool results in is the model's to read.
    def read_only(path)
      return unless path.to_s.start_with?(Scratchpad::RESULTS)

      ToolResult.new(
        content: "#{Scratchpad::RESULTS} holds saved tool results and is read-only. " \
                 "Write under scratchpad/ instead.",
        error: true
      )
    end

    def missing_document(path)
      ToolResult.new(
        content: "No document at #{path.inspect}. Use list_files to see paths.",
        error: true
      )
    end

    # Atomic writes are an explicit backend claim. A false or absent claim
    # preserves the legacy four-method port; a true but incomplete claim fails
    # before the model can rely on safety the backend does not implement.
    def atomic_workspace?(workspace)
      return false unless workspace.respond_to?(:atomic_writes?)

      supported = workspace.atomic_writes?
      unless [true, false].include?(supported)
        raise ConfigurationError, "workspace atomic_writes? must return true or false"
      end
      return false unless supported

      missing = ATOMIC_WORKSPACE_METHODS.reject { |method| workspace.respond_to?(method) }
      unless missing.empty?
        raise ConfigurationError,
              "atomic workspace is missing #{missing.map(&:inspect).join(" and ")}"
      end

      true
    end

    # Absorb the drift real models produce for edit_file only. Ambiguous
    # aliases fail instead of letting hash insertion order choose an edit.
    def tolerate(args)
      normalized = args.each_with_object({}) do |(key, value), copy|
        canonical = ALIASES.fetch(key.to_s, key.to_s)
        if copy.key?(canonical)
          raise ArgumentError, "multiple arguments map to #{canonical.inspect}"
        end

        copy[canonical] = value
      end
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
require_relative "tools/grep"
require_relative "tools/list_files"
require_relative "tools/delete_file"
require_relative "tools/run_code"
require_relative "tools/read_memory"
require_relative "tools/update_memory"
