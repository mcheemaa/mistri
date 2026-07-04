# frozen_string_literal: true

module Mistri
  # Pure fuzzy text replacement: no files, no I/O. This is the string core that
  # a workspace-backed edit tool calls, so it works the same against a database
  # row as against a file on disk.
  #
  # Each edit's old text must match one region and only one, so an edit can
  # never silently change the wrong place. Matching relaxes in two steps: an
  # exact substring first, then a whitespace-tolerant line match that forgives
  # the indentation and trailing-space drift models introduce when they
  # reproduce code they read. Unmatched regions keep their exact bytes,
  # including the file's original line endings.
  module Edit
    Match = Struct.new(:start, :finish, :replacement, :edit_index)

    module_function

    # Apply edits (each {old:, new:}, string or symbol keys) to content and
    # return the new content. Raises EditError when an edit matches nothing,
    # matches more than once, overlaps another, or changes nothing.
    def apply(content, edits)
      normalized = edits.each_with_index.map { |edit, i| normalize(edit, i) }
      matches = normalized.map { |edit| locate(content, edit) }.sort_by(&:start)
      reject_overlaps(matches)

      result = matches.reverse.reduce(content) do |text, match|
        text[0...match.start] + match.replacement + text[match.finish..]
      end
      raise EditError, "the edits changed nothing" if result == content

      result
    end

    def normalize(edit, index)
      edit = edit.transform_keys(&:to_sym)
      old = edit[:old].to_s
      raise EditError, "edits[#{index}] has empty old text" if old.empty?

      { old: old, new: edit[:new].to_s, index: index }
    end

    # Exact match first; on a miss, a whitespace-tolerant line match. Either
    # level must resolve to exactly one region.
    def locate(content, edit)
      exact_match(content, edit) || fuzzy_match(content, edit) ||
        raise(EditError, "edits[#{edit[:index]}] old text was not found")
    end

    def exact_match(content, edit)
      first = content.index(edit[:old])
      return nil unless first

      if content.index(edit[:old], first + 1)
        raise EditError, "edits[#{edit[:index]}] old text matched more than once; " \
                         "add surrounding context to make it unique"
      end
      Match.new(first, first + edit[:old].length, edit[:new], edit[:index])
    end

    # Match the old text's lines against a window of content lines, comparing
    # each line stripped of leading and trailing whitespace. The matched region
    # is the exact original bytes those content lines span.
    def fuzzy_match(content, edit)
      lines = line_spans(content)
      wanted = edit[:old].lines.map(&:strip)
      wanted.pop if wanted.last == "" # a trailing newline in old text is not a line to match
      return nil if wanted.empty?

      windows = matching_windows(lines, wanted)
      return nil if windows.empty?

      if windows.length > 1
        raise EditError, "edits[#{edit[:index]}] old text matched more than once; " \
                         "add surrounding context to make it unique"
      end
      first = windows.first
      Match.new(lines[first][:start], lines[first + wanted.length - 1][:finish],
                edit[:new], edit[:index])
    end

    def matching_windows(lines, wanted)
      (0..(lines.length - wanted.length)).select do |i|
        wanted.each_with_index.all? { |line, j| lines[i + j][:stripped] == line }
      end
    end

    # Each line with its character span in the original and its stripped form.
    def line_spans(content)
      offset = 0
      content.lines.map do |line|
        span = { start: offset, finish: offset + line.length, stripped: line.strip }
        offset += line.length
        span
      end
    end

    def reject_overlaps(matches)
      matches.each_cons(2) do |a, b|
        next if a.finish <= b.start

        raise EditError, "edits[#{a.edit_index}] and edits[#{b.edit_index}] overlap; " \
                         "merge them or target separate regions"
      end
    end
  end
end
