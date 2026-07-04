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

    assert_match(/more than once/, error.message)
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
end
