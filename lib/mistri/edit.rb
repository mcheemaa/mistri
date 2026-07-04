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
    Result = Data.define(:content, :count)

    module_function

    # The model-facing single edit: replace old_string once (unique match
    # required) or everywhere with replace_all. Returns a Result carrying the
    # new content and how many places changed. The replacement adapts to the
    # document's newline style, so an LF-authored new_string dropped into a
    # CRLF document does not mix endings.
    def replace(content, old_string, new_string, replace_all: false)
      old = old_string.to_s
      raise EditError, "old_string is empty" if old.empty?

      new = adapt_newlines(content, new_string.to_s)
      return replace_every(content, old, new) if replace_all

      match = locate(content, { old: old, new: new, index: 0 })
      changed = content[0...match.start] + match.replacement + content[match.finish..]
      raise EditError, "the edit changed nothing" if changed == content

      Result.new(content: changed, count: 1)
    end

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
    # level must resolve to exactly one region. A total miss reports the
    # closest region and its precise difference, so the model's retry can be
    # one-shot.
    def locate(content, edit)
      exact_match(content, edit) || fuzzy_match(content, edit) ||
        raise(EditError, not_found_message(content, edit))
    end

    def replace_every(content, old, new)
      count = content.enum_for(:scan, old).count
      raise EditError, not_found_message(content, { old: old, index: 0 }) if count.zero?

      # Block form keeps both sides literal; a bare string replacement would
      # interpret backslash sequences.
      Result.new(content: content.gsub(old) { new }, count: count)
    end

    # Match the document's dominant newline style so a replacement authored
    # with bare LF does not mix endings into a CRLF document.
    def adapt_newlines(content, text)
      crlf = content.scan("\r\n").length
      bare = content.scan(/(?<!\r)\n/).length
      return text.gsub(/\r?\n/, "\r\n") if crlf > bare

      crlf.positive? || bare.positive? ? text.gsub("\r\n", "\n") : text
    end

    def exact_match(content, edit)
      offsets = occurrence_offsets(content, edit[:old])
      return nil if offsets.empty?

      if offsets.length > 1
        lines = offsets.map { |offset| line_number_at(content, offset) }
        raise EditError, ambiguous_message(edit, lines)
      end
      first = offsets.first
      Match.new(first, first + edit[:old].length, edit[:new], edit[:index])
    end

    def occurrence_offsets(content, needle)
      offsets = []
      offset = content.index(needle)
      while offset
        offsets << offset
        offset = content.index(needle, offset + 1)
      end
      offsets
    end

    def line_number_at(content, offset) = content[0...offset].count("\n") + 1

    def ambiguous_message(edit, line_numbers)
      shown = line_numbers.first(4).join(", ")
      shown += ", ..." if line_numbers.length > 4
      "edits[#{edit[:index]}] old text matched #{line_numbers.length} places " \
        "(lines #{shown}). Add surrounding lines until it is unique, or set " \
        "replace_all: true to change all #{line_numbers.length}."
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

      raise EditError, ambiguous_message(edit, windows.map { |w| w + 1 }) if windows.length > 1

      first = windows.first
      Match.new(lines[first][:start], lines[first + wanted.length - 1][:finish],
                edit[:new], edit[:index])
    end

    # When nothing matched, show the model the closest region and exactly how
    # it differs, so the retry is one shot instead of a guessing loop.
    def not_found_message(content, edit)
      base = "edits[#{edit[:index]}] old text was not found"
      near = nearest_region(content, edit[:old])
      unless near
        return "#{base}. Copy old_string verbatim from read_file output, " \
               "without line-number prefixes."
      end

      "#{base}. Closest region is lines #{near[:from]}-#{near[:to]}; it differs at " \
        "line #{near[:line]}: your text #{near[:yours].inspect} vs the document's " \
        "#{near[:theirs].inspect}#{near[:hint]}. Copy old_string verbatim from " \
        "read_file output, then resend."
    end

    # The window with the most stripped-equal lines, plus its first differing
    # line pair.
    def nearest_region(content, old_text)
      lines = line_spans(content)
      wanted_raw = old_text.lines.map(&:chomp)
      wanted = wanted_raw.map(&:strip)
      wanted.pop && wanted_raw.pop if wanted.last == ""
      return nil if wanted.empty? || lines.length < wanted.length

      best = best_window(lines, wanted)
      return nil unless best

      diff_at = (0...wanted.length).find { |j| lines[best + j][:stripped] != wanted[j] }
      return nil unless diff_at

      yours = wanted_raw[diff_at]
      theirs = content.lines[best + diff_at].to_s.chomp
      hint = yours.strip == theirs.strip ? " (differs only in whitespace)" : ""
      { from: best + 1, to: best + wanted.length, line: best + diff_at + 1,
        yours: yours, theirs: theirs, hint: hint }
    end

    # Score windows by per-line bigram similarity, so a one-character typo in
    # a one-line old_string still finds its region. Only a window at least
    # half-similar overall is worth reporting.
    def best_window(lines, wanted)
      best = nil
      best_score = wanted.length / 2.0
      (0..(lines.length - wanted.length)).each do |i|
        score = (0...wanted.length).sum { |j| similarity(lines[i + j][:stripped], wanted[j]) }
        if score > best_score
          best_score = score
          best = i
        end
      end
      best
    end

    def similarity(left, right)
      return 1.0 if left == right
      return 0.0 if left.empty? || right.empty?

      pairs_left = bigrams(left)
      pairs_right = bigrams(right)
      return 0.0 if pairs_left.empty? || pairs_right.empty?

      (2.0 * (pairs_left & pairs_right).length) / (pairs_left.length + pairs_right.length)
    end

    def bigrams(text) = (0...(text.length - 1)).map { |i| text[i, 2] }.uniq

    def matching_windows(lines, wanted)
      (0..(lines.length - wanted.length)).select do |i|
        wanted.each_with_index.all? { |line, j| lines[i + j][:stripped] == line }
      end
    end

    # Each line with its character span in the original and its stripped form.
    # A leading BOM is invisible to matching, and the first span starts after
    # it, so a replacement at the top of the document never swallows it.
    def line_spans(content)
      offset = 0
      content.lines.map do |line|
        bom = offset.zero? && line.start_with?("\uFEFF") ? 1 : 0
        span = { start: offset + bom, finish: offset + line.length,
                 stripped: line.delete_prefix("\uFEFF").strip }
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
