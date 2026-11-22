# frozen_string_literal: true

module Mistri
  module Tools
    MAX_PATTERN_CHARS = 500
    MAX_SEARCHED_BYTES = 5_000_000
    # Characters shown on each side of a match on a long line.
    MATCH_WINDOW_CHARS = 150

    module_function

    def grep(workspace)
      Tool.define("grep",
                  "Search documents with a regular expression. Returns each match with its " \
                  "path and line number, or a count. On a very long line, each match comes " \
                  "with the characters around it and its column.",
                  schema: lambda {
                    string :pattern, "Regular expression", required: true
                    string :path, "A document, or a folder to search every document under. " \
                                  "Without it, every document"
                    string :output_mode, "content for the matches (the default), count for " \
                                         "how many there are", enum: %w[content count]
                    integer :context, "Lines to show around each match (default 0)"
                    integer :head_limit, "Matches to show at most (default 50)"
                  }) do |args|
        Search.new(workspace, args).call
      end
    end

    # One grep call: the documents under a path, searched line by line.
    class Search
      def initialize(workspace, args)
        @workspace = workspace
        @path = args["path"]
        @pattern = args["pattern"].to_s
        @count_only = args["output_mode"] == "count"
        @context = args["context"].to_i.clamp(0, 10)
        @limit = (args["head_limit"] || 50).to_i.clamp(1, 200)
        @blocks = []
        @shown = 0
        @matches = 0
        @lines = 0
        @searched = 0
      end

      def call
        if @pattern.length > MAX_PATTERN_CHARS
          return failure("The pattern is longer than #{MAX_PATTERN_CHARS} characters.")
        end

        regexp = Regexp.new(@pattern, timeout: 1.0)
        paths = documents
        if paths.empty?
          return failure("No document at or under #{@path.inspect}. Use list_files to see paths.")
        end

        paths.each { |path| break if search(path, regexp) > MAX_SEARCHED_BYTES }
        report
      rescue RegexpError => e
        failure("The pattern could not be used: #{e.message}")
      end

      private

      def failure(text) = ToolResult.new(content: text, error: true)

      def documents
        paths = @workspace.list(@path)
        return paths unless @path

        folder = "#{@path.delete_suffix("/")}/"
        paths.select { |path| path == @path || path.start_with?(folder) }
      end

      def search(path, regexp)
        content = @workspace.read(path).to_s
        lines = content.lines
        lines.each_with_index do |line, index|
          found = line.enum_for(:scan, regexp).map { Regexp.last_match }
          next if found.empty?

          @lines += 1
          @matches += found.length
          show(path, lines, index, found) unless @count_only
        end
        @searched += content.bytesize
      end

      def show(path, lines, index, found)
        line = lines[index]
        if line.length > LONG_LINE_CHARS
          found.first([@limit - @shown, 0].max).each do |match|
            @blocks << around(path, index, line, match)
            @shown += 1
          end
        elsif @shown < @limit
          @blocks << with_context(path, lines, index)
          @shown += found.length
        end
      end

      def with_context(path, lines, index)
        from = [index - @context, 0].max
        to = [index + @context, lines.length - 1].min
        (from..to).map { |n| "#{path}:#{n + 1}: #{lines[n].chomp[0, LONG_LINE_CHARS]}" }.join("\n")
      end

      def around(path, index, line, match)
        from = [match.begin(0) - MATCH_WINDOW_CHARS, 0].max
        to = [match.end(0) + MATCH_WINDOW_CHARS, line.length].min
        "#{path}:#{index + 1}:#{match.begin(0)}: #{"..." if from.positive?}" \
          "#{line[from...to].chomp}#{"..." if to < line.length}"
      end

      def report
        return "#{@matches} matches in #{@lines} lines#{stopped}" if @count_only
        return "No matches.#{stopped}" if @matches.zero?

        text = @blocks.join("\n--\n")
        if text.length > MAX_READ_CHARS
          text = "#{text[0, MAX_READ_CHARS]}\n[cut at #{MAX_READ_CHARS} characters]"
        end
        more = if @matches > @shown
                 "\n[#{@matches} matches in all, #{@shown} shown. Narrow the pattern or " \
                   "raise head_limit.]"
               end
        "#{text}#{more}#{stopped}"
      end

      def stopped
        return unless @searched > MAX_SEARCHED_BYTES

        "\n[The search stopped after #{MAX_SEARCHED_BYTES} bytes. Pass a path to search the rest.]"
      end
    end
    private_constant :Search
  end
end
