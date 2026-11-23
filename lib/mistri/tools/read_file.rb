# frozen_string_literal: true

module Mistri
  module Tools
    MAX_READ_BYTES = 20_000
    LONG_LINE_CHARS = 2_000
    WINDOW_MARGIN_BYTES = 400
    private_constant :WINDOW_MARGIN_BYTES

    module_function

    def read_file(workspace)
      tool = Tool.define("read_file",
                         "Read a document. Lines come back with their numbers, at most " \
                         "#{MAX_READ_BYTES} bytes a call: pass offset and limit to read " \
                         "further. A very long line is shown cut, with the offset to read on " \
                         "from with unit \"characters\". The first line states the document's " \
                         "version, which write_file takes as if_version.",
                         save_result: false,
                         schema: lambda {
                           string :path, "Document path", required: true
                           integer :offset, "The line to start at, from 1. With unit characters, " \
                                            "the character, from 0"
                           integer :limit, "How many lines, or characters, to read"
                           string :unit, "lines (the default) or characters",
                                  enum: %w[lines characters]
                         }) do |args, context|
        with_document(workspace, args) do |content|
          Tools.window(args["path"], content, args["offset"], args["limit"], args["unit"],
                       bytes: window_bytes(context))
        end
      end
      bind(workspace, tool)
    end

    # A tool that reads in parts keeps its part under the limit in force, so
    # a cut never takes the line that says how to read on.
    def window_bytes(context)
      limit = context&.result_limit
      return MAX_READ_BYTES unless limit

      (limit - WINDOW_MARGIN_BYTES).clamp(WINDOW_MARGIN_BYTES, MAX_READ_BYTES)
    end

    def window(path, content, offset = nil, limit = nil, unit = nil, bytes: MAX_READ_BYTES)
      title = "#{path}, version #{version(content)}"
      return "#{title}, empty." if content.empty?
      return "#{title}, #{content.bytesize} bytes that are not text." unless content.valid_encoding?
      if unit == "characters"
        return character_window(title, content, offset.to_i, limit.to_i, bytes)
      end

      line_window(title, content.lines, [offset.to_i, 1].max, limit.to_i, bytes)
    end

    def line_window(title, lines, from, limit, bytes)
      return "#{title}, #{lines.length} lines. Line #{from} is past the end." if from > lines.length

      shown = shown_lines(lines, from, limit.positive? ? limit : lines.length, bytes)
      last = from + shown.length - 1
      more = lines.length - last
      rest = more.positive? ? "\n[#{more} more lines. Continue with offset #{last + 1}.]" : ""
      "#{title}, lines #{from}-#{last} of #{lines.length}:\n#{shown.join("\n")}#{rest}"
    end

    def shown_lines(lines, from, limit, bytes)
      size = 0
      offset = lines.first(from - 1).sum(&:length)
      lines[from - 1, limit].each_with_index.with_object([]) do |(line, index), shown|
        entry = "#{from + index}: #{shown_line(line.chomp, offset, bytes)}"
        break shown if size + entry.bytesize > bytes && shown.any?

        shown << entry
        size += entry.bytesize + 1
        offset += line.length
      end
    end

    def shown_line(line, offset, bytes)
      kept = fitting(line[0, LONG_LINE_CHARS], bytes)
      return line if kept.length == line.length

      "#{kept} [line cut: #{line.length - kept.length} more characters. Read on with unit " \
        "characters and offset #{offset + kept.length}.]"
    end

    def fitting(text, bytes)
      text.bytesize > bytes ? text.byteslice(0, bytes).scrub("") : text
    end

    def character_window(title, content, from, limit, bytes)
      from = from.clamp(0, content.length)
      part = fitting(content[from, limit.positive? ? [limit, bytes].min : bytes], bytes)
      last = from + part.length
      more = content.length - last
      rest = more.positive? ? "\n[#{more} more characters. Continue with offset #{last}.]" : ""
      "#{title}, characters #{from}-#{last} of #{content.length}:\n#{part}#{rest}"
    end
  end
end
