# frozen_string_literal: true

module Mistri
  module Tools
    MAX_READ_CHARS = 20_000
    LONG_LINE_CHARS = 2_000

    module_function

    def read_file(workspace)
      Tool.define("read_file",
                  "Read a document. Lines come back with their numbers, at most " \
                  "#{MAX_READ_CHARS} characters a call: pass offset and limit to read " \
                  "further. For a very long line, pass unit \"characters\" to read it by " \
                  "character offset. The first line states the document's version, which " \
                  "write_file takes as if_version.",
                  save_result: false,
                  schema: lambda {
                    string :path, "Document path", required: true
                    integer :offset, "The line to start at, from 1. With unit characters, " \
                                     "the character, from 0"
                    integer :limit, "How many lines, or characters, to read"
                    string :unit, "lines (the default) or characters", enum: %w[lines characters]
                  }) do |args|
        with_document(workspace, args) do |content|
          Tools.window(args["path"], content, args["offset"], args["limit"], args["unit"])
        end
      end
    end

    def window(path, content, offset = nil, limit = nil, unit = nil)
      title = "#{path}, version #{version(content)}"
      return "#{title}, empty." if content.empty?
      return character_window(title, content, offset.to_i, limit.to_i) if unit == "characters"

      line_window(title, content.lines, [offset.to_i, 1].max, limit.to_i)
    end

    def line_window(title, lines, from, limit)
      return "#{title}, #{lines.length} lines. Line #{from} is past the end." if from > lines.length

      shown = shown_lines(lines, from, limit.positive? ? limit : lines.length)
      last = from + shown.length - 1
      more = lines.length - last
      rest = more.positive? ? "\n[#{more} more lines. Continue with offset #{last + 1}.]" : ""
      "#{title}, lines #{from}-#{last} of #{lines.length}:\n#{shown.join("\n")}#{rest}"
    end

    def shown_lines(lines, from, limit)
      size = 0
      lines[from - 1, limit].each_with_index.with_object([]) do |(line, index), shown|
        line = line.chomp
        if line.length > LONG_LINE_CHARS
          line = "#{line[0, LONG_LINE_CHARS]} [line cut: #{line.length - LONG_LINE_CHARS} more " \
                 "characters, read them with unit characters]"
        end
        break shown if size + line.length > MAX_READ_CHARS && shown.any?

        shown << "#{from + index}: #{line}"
        size += line.length
      end
    end

    def character_window(title, content, from, limit)
      from = from.clamp(0, content.length)
      part = content[from, limit.positive? ? [limit, MAX_READ_CHARS].min : MAX_READ_CHARS]
      last = from + part.length
      more = content.length - last
      rest = more.positive? ? "\n[#{more} more characters. Continue with offset #{last}.]" : ""
      "#{title}, characters #{from}-#{last} of #{content.length}:\n#{part}#{rest}"
    end
  end
end
