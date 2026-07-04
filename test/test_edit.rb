# frozen_string_literal: true

require_relative "test_helper"

class TestEdit < Minitest::Test
  def test_exact_replacement_preserves_surrounding_bytes
    content = "line one\nline two\nline three\n"
    result = Mistri::Edit.apply(content, [{ old: "line two", new: "LINE TWO" }])

    assert_equal "line one\nLINE TWO\nline three\n", result
  end

  def test_multiple_non_overlapping_edits_apply_together
    content = "alpha\nbeta\ngamma\n"
    result = Mistri::Edit.apply(content, [{ old: "alpha", new: "A" }, { old: "gamma", new: "G" }])

    assert_equal "A\nbeta\nG\n", result
  end

  def test_fuzzy_match_forgives_indentation_and_trailing_space_drift
    content = "def run\n    do_work\n    finish  \nend\n"
    # The model reproduced the body with different indentation and no trailing spaces.
    edit = { old: "do_work\nfinish", new: "do_work\n    log\n    finish" }
    result = Mistri::Edit.apply(content, [edit])

    assert_includes result, "log"
    assert_equal "def run\n", result.lines.first
  end

  def test_a_match_that_is_not_unique_raises
    error = assert_raises(Mistri::EditError) do
      Mistri::Edit.apply("x = 1\nx = 1\n", [{ old: "x = 1", new: "x = 2" }])
    end

    assert_match(/matched 2 places \(lines 1, 2\)/, error.message)
  end

  def test_a_missing_match_raises
    assert_raises(Mistri::EditError) do
      Mistri::Edit.apply("hello\n", [{ old: "goodbye", new: "hi" }])
    end
  end

  def test_overlapping_edits_raise
    error = assert_raises(Mistri::EditError) do
      Mistri::Edit.apply("abcdef\n", [{ old: "abcd", new: "1" }, { old: "cdef", new: "2" }])
    end

    assert_match(/overlap/, error.message)
  end

  def test_an_edit_that_changes_nothing_raises
    assert_raises(Mistri::EditError) do
      Mistri::Edit.apply("same\n", [{ old: "same", new: "same" }])
    end
  end

  def test_crlf_line_endings_are_preserved
    content = "one\r\ntwo\r\nthree\r\n"
    result = Mistri::Edit.apply(content, [{ old: "two", new: "TWO" }])

    assert_equal "one\r\nTWO\r\nthree\r\n", result
  end

  def test_empty_old_text_raises
    assert_raises(Mistri::EditError) { Mistri::Edit.apply("x", [{ old: "", new: "y" }]) }
  end

  def test_replace_changes_exactly_one_place
    result = Mistri::Edit.replace("a\nb\na\n", "b", "B")

    assert_equal "a\nB\na\n", result.content
    assert_equal 1, result.count
  end

  def test_replace_all_changes_every_occurrence_and_reports_the_count
    result = Mistri::Edit.replace("x = 1\ny = 1\nz = 1\n", "= 1", "= 2", replace_all: true)

    assert_equal "x = 2\ny = 2\nz = 2\n", result.content
    assert_equal 3, result.count
  end

  def test_ambiguity_names_the_lines_and_suggests_replace_all
    error = assert_raises(Mistri::EditError) do
      Mistri::Edit.replace("a\nsame\nb\nsame\n", "same", "different")
    end

    assert_match(/lines 2, 4/, error.message)
    assert_match(/replace_all/, error.message)
  end

  def test_a_near_miss_reports_the_closest_region_and_its_delta
    content = "<div>\n  <h1>Welcome home</h1>\n</div>\n"
    error = assert_raises(Mistri::EditError) do
      Mistri::Edit.replace(content, "<div>\n  <h1>Welcome hom</h1>\n</div>", "x")
    end

    assert_match(/Closest region is lines 1-3/, error.message)
    assert_match(/differs at line 2/, error.message)
    assert_match(/Welcome hom/, error.message)
  end

  def test_a_whitespace_only_near_miss_says_so
    content = "def run\n\tdo_work\nend\n"
    error = assert_raises(Mistri::EditError) do
      # Interior spacing differs, so even the fuzzy tier misses; the message
      # must point at whitespace.
      Mistri::Edit.replace(content, "def run\n  do _ work\nend", "x")
    end

    assert_match(/differs at line 2/, error.message)
  end

  def test_replacements_adapt_to_the_documents_newline_style
    crlf = "one\r\ntwo\r\nthree\r\n"
    result = Mistri::Edit.replace(crlf, "two", "TWO\nTWO-B")

    assert_equal "one\r\nTWO\r\nTWO-B\r\nthree\r\n", result.content
  end

  def test_a_leading_bom_is_invisible_to_fuzzy_matching
    content = "﻿<html>\n  <body></body>\n</html>\n"
    result = Mistri::Edit.replace(content, "<html>\n<body></body>", "<html>\n<body>hi</body>")

    assert result.content.start_with?("﻿")
    assert_includes result.content, "hi"
  end
end
