# frozen_string_literal: true

module Mistri
  module Tools
    MAX_PATTERN_CHARS = 500
    MAX_SEARCHED_BYTES = 5_000_000
    MAX_SEARCH_SECONDS = 5
    MATCH_SIDE_CHARS = 150

    module_function

    def grep(workspace, seconds: MAX_SEARCH_SECONDS)
      Tool.define("grep",
                  "Search documents with a regular expression. Returns each match with its " \
                  "path and line number, or a count. On a very long line, each match comes " \
                  "with the characters around it and its character offset in the document, " \
                  "which read_file takes with unit \"characters\".",
                  save_result: false,
                  schema: lambda {
                    string :pattern, "Regular expression", required: true
                    string :path, "A document, or a folder to search every document under. " \
                                  "Without it, every document"
                    string :output_mode, "content for the matches (the default), count for " \
                                         "how many there are", enum: %w[content count]
                    integer :context, "Lines to show around each match (default 0)"
                    integer :head_limit, "Matches to show at most (default 50)"
                  }) do |args, context|
        Search.new(workspace, args, seconds:, bytes: window_bytes(context)).call
      end
    end

    # One grep call: the documents under a path, searched line by line.
    class Search
      Line = Data.define(:path, :index, :text, :offset)
      private_constant :Line

      def initialize(workspace, args, seconds:, bytes:)
        @workspace = workspace
        @seconds = seconds
        @bytes = bytes
        @path = args["path"]
        @pattern = args["pattern"].to_s
        @count_only = args["output_mode"] == "count"
        @context = args["context"].to_i.clamp(0, 10)
        @limit = (args["head_limit"] || 50).to_i.clamp(1, 200)
        @blocks = []
        @size = 0
        @shown = 0
        @matches = 0
        @lines = 0
        @searched = 0
      end

      def call
        if @pattern.length > MAX_PATTERN_CHARS
          return failure("The pattern is longer than #{MAX_PATTERN_CHARS} characters.")
        end

        unusable = @path && Tools.unusable_path(@path, prefix: true)
        return unusable if unusable

        regexp = Regexp.new(@pattern, timeout: 1.0)
        paths = documents
        if paths.empty?
          return failure("No document at or under #{@path.inspect}. Use list_files to see paths.")
        end

        @deadline = clock + @seconds
        paths.each { |path| break if search(path, regexp) > MAX_SEARCHED_BYTES || @late }
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
        offset = 0
        lines.each_with_index do |text, index|
          break @late = true if clock > @deadline

          count, found = matches_on(text, regexp)
          if count.positive?
            @lines += 1
            @matches += count
            show(lines, Line.new(path:, index:, text:, offset:), count, found) unless @count_only
          end
          offset += text.length
        end
        @searched += content.bytesize
      end

      # Only the matches that can still be shown are kept, so a pattern that
      # matches at every character of a large line holds no more than those.
      def matches_on(line, regexp)
        count = 0
        found = []
        keep = @count_only || line.length <= LONG_LINE_CHARS ? 0 : @limit - @shown
        line.scan(regexp) do
          count += 1
          found << Regexp.last_match if found.length < keep
        end
        [count, found]
      end

      def show(lines, line, count, found)
        if line.text.length > LONG_LINE_CHARS
          found.each { |match| add(around(line, match), 1) }
        elsif @shown < @limit
          add(with_context(line.path, lines, line.index), count)
        end
      end

      def add(block, matches)
        @full ||= @blocks.any? && @size + block.bytesize > @bytes
        return if @full

        @blocks << block
        @size += block.bytesize + 4
        @shown += matches
      end

      def with_context(path, lines, index)
        from = [index - @context, 0].max
        to = [index + @context, lines.length - 1].min
        (from..to).map { |n| "#{path}:#{n + 1}: #{lines[n].chomp[0, LONG_LINE_CHARS]}" }.join("\n")
      end

      def around(line, match)
        text = line.text
        from = [match.begin(0) - MATCH_SIDE_CHARS, 0].max
        to = [match.end(0) + MATCH_SIDE_CHARS, text.length].min
        "#{line.path}:#{line.index + 1}: [character #{line.offset + match.begin(0)}] " \
          "#{"..." if from.positive?}#{text[from...to].chomp}#{"..." if to < text.length}"
      end

      def report
        return "#{@matches} matches in #{@lines} lines#{stopped}" if @count_only
        return "No matches.#{stopped}" if @matches.zero?

        found = @blocks.join("\n--\n")
        text = Tools.fitting(found, @bytes)
        text = "#{text}\n[cut at #{@bytes} bytes]" if text.bytesize < found.bytesize
        "#{text}#{more}#{stopped}"
      end

      def more
        return unless @matches > @shown

        advice = @full ? "pass a path" : "raise head_limit"
        "\n[#{@matches} matches in all, #{@shown} shown. Narrow the pattern or #{advice}.]"
      end

      # The timeout of the pattern is for one match, so the whole search has
      # a deadline of its own.
      def stopped
        if @late
          "\n[The search stopped after #{@seconds} seconds. Pass a path or a simpler pattern " \
            "to search the rest.]"
        elsif @searched > MAX_SEARCHED_BYTES
          "\n[The search stopped after #{MAX_SEARCHED_BYTES} bytes. Pass a path to search the " \
            "rest.]"
        end
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_constant :Search
  end
end
