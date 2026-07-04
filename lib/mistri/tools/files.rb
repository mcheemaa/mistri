# frozen_string_literal: true

module Mistri
  # Built-in tools. Tools.files binds the document tools to a workspace.
  #
  # The edit tool's model-facing shape is flat {path, old_string, new_string,
  # replace_all} on purpose: it is the shape frontier models are trained on,
  # and nested edit arrays measurably degrade their calls. The multi-edit
  # engine stays internal. A tolerance layer at the boundary absorbs the alias
  # keys and stringly booleans real sessions produce.
  module Tools
    MAX_READ_CHARS = 20_000
    ALIASES = { "oldText" => "old_string", "old" => "old_string", "search" => "old_string",
                "newText" => "new_string", "new" => "new_string", "replace" => "new_string",
                "replaceAll" => "replace_all", "file" => "path", "filename" => "path" }.freeze

    module_function

    def files(workspace)
      [read_file(workspace), write_file(workspace), edit_file(workspace),
       find_in_file(workspace), list_files(workspace)]
    end

    def read_file(workspace)
      Tool.define("read_file",
                  "Read a document with line numbers. Use offset and limit for a window " \
                  "into a long document.",
                  schema: lambda {
                    string :path, "Document path", required: true
                    integer :offset, "First line to read (1-based)"
                    integer :limit, "How many lines to read"
                  }) do |args|
        with_document(workspace, args) do |content|
          Tools.numbered_window(content, args["offset"], args["limit"])
        end
      end
    end

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

    def edit_file(workspace)
      Tool.define("edit_file",
                  "Replace an exact snippet of a document. Copy old_string verbatim from " \
                  "read_file output including whitespace, without line-number prefixes. " \
                  "It must match exactly one place; add surrounding lines to make it " \
                  "unique, or set replace_all to change every occurrence.",
                  eager_input_streaming: true,
                  schema: lambda {
                    string :path, "Document path", required: true
                    string :old_string, "Exact text to replace (whitespace matters)", required: true
                    string :new_string, "Replacement text", required: true
                    boolean :replace_all, "Replace every occurrence instead of exactly one"
                  }) do |args|
        args = Tools.tolerate(args)
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

    def find_in_file(workspace)
      Tool.define("find_in_file",
                  "Find text in a document. Returns line-numbered matches with context, " \
                  "so you can locate a region without reading the whole document.",
                  schema: lambda {
                    string :path, "Document path", required: true
                    string :query, "Text to find (plain substring)", required: true
                    integer :context, "Context lines around each match"
                  }) do |args|
        with_document(workspace, args) do |content|
          Tools.find_matches(content, args["query"], (args["context"] || 2).to_i)
        end
      end
    end

    def list_files(workspace)
      Tool.define("list_files",
                  "List document paths in the workspace, optionally under a prefix.",
                  schema: -> { string :prefix, "Only paths starting with this" }) do |args|
        paths = workspace.list(args["prefix"])
        paths.empty? ? "No documents found." : paths.join("\n")
      end
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

    def numbered_window(content, offset, limit)
      lines = content.lines
      from = [(offset || 1).to_i, 1].max
      to = limit ? [from + limit.to_i - 1, lines.length].min : lines.length
      numbered = (from..to).map { |n| "#{n}: #{lines[n - 1]}" }.join
      Tools.truncate_chars(numbered, lines.length, from, to)
    end

    def truncate_chars(text, total_lines, from, to)
      windowed = to < total_lines || from > 1
      suffix = windowed ? "\n[showing lines #{from}-#{to} of #{total_lines}]" : ""
      if text.length > MAX_READ_CHARS
        cut = text[0, MAX_READ_CHARS]
        cut = cut[0..(cut.rindex("\n") || -1)]
        "#{cut}\n[truncated at #{MAX_READ_CHARS} chars; use offset/limit to read more]"
      else
        "#{text}#{suffix}"
      end
    end

    def find_matches(content, query, context)
      lines = content.lines
      hits = lines.each_index.select { |i| lines[i].include?(query) }
      return "No matches for #{query.inspect}." if hits.empty?

      blocks = hits.first(20).map do |hit|
        from = [hit - context, 0].max
        to = [hit + context, lines.length - 1].min
        (from..to).map { |n| "#{n + 1}: #{lines[n]}" }.join
      end
      notice = hits.length > 20 ? "\n[#{hits.length - 20} more matches not shown]" : ""
      "#{blocks.join("---\n")}#{notice}"
    end
  end
end
