# frozen_string_literal: true

module Mistri
  module Tools
    module_function

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
