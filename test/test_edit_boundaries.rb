# frozen_string_literal: true

require_relative "test_helper"

# Fuzzy matching forgives whitespace drift, not the ownership of line separators.
class TestEditBoundaries < Minitest::Test
  def test_fuzzy_replacements_only_consume_explicit_final_newlines
    cases = [
      ["alpha\nbeta", "A\nB", "before\nA\nB\nafter\n"],
      ["alpha\nbeta\n", "A\nB", "before\nA\nBafter\n"],
      ["alpha\nbeta", "A\nB\n", "before\nA\nB\n\nafter\n"],
      ["alpha\nbeta\n", "A\nB\n", "before\nA\nB\nafter\n"],
      ["alpha\nbeta", "", "before\n\nafter\n"],
      ["alpha\nbeta\n", "", "before\nafter\n"]
    ]
    ["\n", "\r\n"].each do |newline|
      content = "before\n  alpha  \n  beta\t\nafter\n".gsub("\n", newline)

      cases.each do |old, replacement, expected|
        assert_fuzzy_edit(expected.gsub("\n", newline), content,
                          old.gsub("\n", newline), replacement.gsub("\n", newline))
      end
    end
  end

  def test_an_unterminated_final_line_does_not_gain_an_implicit_newline
    [false, true].each do |terminated|
      old = terminated ? "alpha\nbeta\n" : "alpha\nbeta"

      assert_fuzzy_edit("before\nA\nB", "before\n  alpha\n  beta", old, "A\nB")
      assert_fuzzy_edit("before\nA\nB\n", "before\n  alpha\n  beta", old, "A\nB\n")
    end
  end

  def test_a_terminated_final_line_keeps_its_unmatched_newline
    assert_fuzzy_edit("before\nA\nB\n", "before\n  alpha\n  beta\n", "alpha\nbeta", "A\nB")
  end

  def test_mixed_line_endings_outside_the_match_are_unchanged
    assert_fuzzy_edit("before\r\nA\nB\r\nafter\nlast\n",
                      "before\r\n  alpha\n  beta\r\nafter\nlast\n", "alpha\nbeta", "A\nB")
  end

  def test_bom_and_multibyte_characters_do_not_shift_boundaries
    assert_fuzzy_edit("\uFEFFhéader\r\nCafé\r\n完了\r\n末尾\r\n",
                      "\uFEFFhéader\r\n  café  \r\n  fin  \r\n末尾\r\n",
                      "café\nfin", "Café\r\n完了")
    assert_fuzzy_edit("\uFEFFCafé\n完了\nsuffix\n", "\uFEFF  café\n  fin\nsuffix\n",
                      "café\nfin", "Café\n完了")
  end

  def test_trailing_blank_lines_are_part_of_the_anchor
    assert_fuzzy_edit("before\nA\nafter\n", "before\n  alpha  \n\n\nafter\n",
                      "alpha\n\n\n", "A\n")
    assert_fuzzy_edit("before\nA\nafter\n", "before\n  alpha  \n \t\nafter\n",
                      "alpha\n \n", "A\n")
  end

  def test_a_trailing_blank_line_can_disambiguate_fuzzy_matches
    assert_fuzzy_edit("  alpha  \nfirst\nA\nlast\n", "  alpha  \nfirst\n  alpha  \n\nlast\n",
                      "alpha\n\n", "A\n")
  end

  def test_a_missing_trailing_blank_line_cannot_match
    content = "before\n  alpha  \nafter\n"
    error = assert_raises(Mistri::EditError) do
      Mistri::Edit.replace(content, "alpha\n\n", "A\n")
    end

    assert_match(/old text was not found/, error.message)
    assert_equal "before\n  alpha  \nafter\n", content
  end

  def test_a_single_whitespace_only_line_cannot_be_a_fuzzy_anchor
    [false, true].each do |terminated|
      old = terminated ? "\t\n" : "\t"

      assert_raises(Mistri::EditError) { Mistri::Edit.replace("\n", old, "X") }
      assert_raises(Mistri::EditError) do
        Mistri::Edit.apply("\n", [{ old: old, new: "X" }])
      end
    end
  end

  def test_whitespace_only_anchors_cannot_insert_at_the_same_boundary
    assert_raises(Mistri::EditError) do
      Mistri::Edit.apply("\n", [{ old: "\t", new: "X" }, { old: " ", new: "Y" }])
    end
  end

  def test_near_miss_diagnostics_count_real_trailing_blank_lines
    error = assert_raises(Mistri::EditError) do
      Mistri::Edit.replace("  alpha\n  betx\n\nsuffix\n", "alpha\nbeta\n\n", "A\n")
    end

    assert_match(/Closest region is lines 1-3/, error.message)
    assert_match(/differs at line 2/, error.message)
  end

  def test_adjacent_fuzzy_edits_leave_each_unmatched_separator_intact
    edits = [{ old: "alpha\nbeta", new: "A\nB" }, { old: "gamma\ndelta", new: "G\nD" }]
    result = Mistri::Edit.apply("before\n  alpha\n  beta\n  gamma\n  delta\nafter\n", edits)

    assert_equal "before\nA\nB\nG\nD\nafter\n", result
  end

  def test_an_explicit_blank_line_is_included_in_overlap_detection
    content = "  alpha  \n\n  beta\nsuffix\n"
    error = assert_raises(Mistri::EditError) do
      Mistri::Edit.apply(content, [{ old: "alpha\n\n", new: "A\n" },
                                   { old: "\nbeta", new: "B" }])
    end

    assert_match(/overlap/, error.message)
    assert_equal "  alpha  \n\n  beta\nsuffix\n", content
  end

  def test_duplicate_fuzzy_windows_remain_ambiguous
    error = assert_raises(Mistri::EditError) do
      Mistri::Edit.replace("  alpha\n  beta\n  alpha\n  beta\n", "alpha\nbeta", "A\nB")
    end

    assert_match(/matched 2 places \(lines 1, 3\)/, error.message)
  end

  def test_exact_matching_still_takes_precedence_over_fuzzy_candidates
    content = "  alpha\n  beta\nalpha\nbeta\nafter\n"

    assert_equal "  alpha\n  beta\nA\nB\nafter\n",
                 Mistri::Edit.replace(content, "alpha\nbeta", "A\nB").content
  end

  def test_replace_all_remains_exact_only
    assert_raises(Mistri::EditError) do
      Mistri::Edit.replace("  alpha\n  beta\n", "alpha\nbeta", "A\nB", replace_all: true)
    end
    result = Mistri::Edit.replace("alpha\nbeta\nalpha\nbeta\n", "alpha\nbeta", "A\nB",
                                  replace_all: true)

    assert_equal "A\nB\nA\nB\n", result.content
    assert_equal 2, result.count
  end

  def test_replace_adapts_newlines_but_apply_keeps_replacement_bytes
    content = "before\r\n  alpha\r\n  beta\r\nafter\r\n"
    result = Mistri::Edit.replace(content, "alpha\nbeta", "A\nB")

    assert_equal "before\r\nA\r\nB\r\nafter\r\n", result.content
    assert_equal "before\r\nA\nB\r\nafter\r\n",
                 Mistri::Edit.apply(content, [{ old: "alpha\nbeta", new: "A\nB" }])
  end

  private

  def assert_fuzzy_edit(expected, content, old, replacement)
    refute_includes content, old
    assert_equal expected, Mistri::Edit.apply(content, [{ old: old, new: replacement }])
    result = Mistri::Edit.replace(content, old, replacement)

    assert_equal expected, result.content
    assert_equal 1, result.count
  end
end
