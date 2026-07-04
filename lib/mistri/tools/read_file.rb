# frozen_string_literal: true

module Mistri
  module Tools
    MAX_READ_CHARS = 20_000

    module_function

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

    def numbered_window(content, offset, limit)
      lines = content.lines
      from = [(offset || 1).to_i, 1].max
      to = limit ? [from + limit.to_i - 1, lines.length].min : lines.length
      numbered = (from..to).map { |n| "#{n}: #{lines[n - 1]}" }.join
      windowed = to < lines.length || from > 1
      suffix = windowed ? "\n[showing lines #{from}-#{to} of #{lines.length}]" : ""
      return "#{numbered}#{suffix}" if numbered.length <= MAX_READ_CHARS

      cut = numbered[0, MAX_READ_CHARS]
      cut = cut[0..(cut.rindex("\n") || -1)]
      "#{cut}\n[truncated at #{MAX_READ_CHARS} chars; use offset/limit to read more]"
    end
  end
end
