# frozen_string_literal: true

require_relative "test_helper"

class TestGrep < Minitest::Test
  def setup
    @workspace = Mistri::Workspace::Memory.new
    @tools = Mistri::Tools.files(@workspace).to_h { |tool| [tool.name, tool] }
  end

  def test_grep_takes_a_pattern_across_a_folder_with_context_or_a_count
    @workspace.write("notes/a.md", "alpha\nrefund 12\nomega\n")
    @workspace.write("notes/b.md", "refund 7\n")
    @workspace.write("notes-old/c.md", "refund 99\n")

    found = @tools["grep"].call({ "pattern" => "refund \\d+", "path" => "notes", "context" => 1 })
    count = @tools["grep"].call({ "pattern" => "refund", "output_mode" => "count" })

    assert_equal "notes/a.md:1: alpha\nnotes/a.md:2: refund 12\nnotes/a.md:3: omega\n--\n" \
                 "notes/b.md:1: refund 7", found
    assert_equal "3 matches in 3 lines", count
  end

  def test_grep_shows_a_match_on_a_long_line_with_what_is_around_it
    @workspace.write("rows.json", "[#{"{\"id\":1}," * 1_000}{\"id\":\"last\"}]")

    found = @tools["grep"].call({ "pattern" => "last" })

    assert_match(/\Arows\.json:1: \[character 9008\] \.\.\./, found)
    assert_operator found.length, :<, 400
  end

  def test_grep_leaves_out_a_document_that_is_not_text_and_says_so
    @workspace.write("logo.png", "\x89PNG\xFF".dup.force_encoding(Encoding::UTF_8))
    @workspace.write("notes.md", "PNG is a format")

    found = @tools["grep"].call({ "pattern" => "PNG" })

    assert_equal "notes.md:1: PNG is a format\n" \
                 "[Documents that are not text were not searched: 1.]", found
  end

  def test_grep_stops_a_search_that_takes_too_long
    @workspace.write("slow.txt", "#{"a" * 22}!\n" * 40)

    result = Mistri::Tools.grep(@workspace, seconds: 0.01).call({ "pattern" => '^(a+)+\1$' })

    assert_match(/\ANo matches\.\n\[The search stopped after 0\.01 seconds/, result)
  end

  def test_grep_stops_inside_one_line_whose_matches_take_too_long
    @workspace.write("slow.txt", "#{"a" * 20}!" * 40)

    result = Mistri::Tools.grep(@workspace, seconds: 0.01)
                          .call({ "pattern" => '(a+)+\1$|!', "output_mode" => "count" })

    assert_operator result[/\A(\d+) matches in 1 lines/, 1].to_i, :<, 40
    assert_match(/\[The search stopped after 0\.01 seconds/, result)
  end

  def test_grep_refuses_what_it_cannot_search_and_says_what_it_left_out
    @workspace.write("refunds.md", (1..300).map { |n| "refund #{n} #{"x" * 90}\n" }.join)
    grep = @tools["grep"]

    long = grep.call({ "pattern" => "a" * 501 })
    outside = grep.call({ "pattern" => "refund", "path" => "../notes" })
    few = grep.call({ "pattern" => "refund", "head_limit" => 5 })
    many = grep.call({ "pattern" => "refund", "head_limit" => 200 })

    assert_match(/The pattern is longer than 500 characters/, long.content)
    assert_match(/is not a path here/, outside.content)
    assert_match(/\[300 matches in all, 5 shown\. Narrow the pattern or raise head_limit\.\]\z/,
                 few)
    assert_match(/\[300 matches in all, \d+ shown\. Narrow the pattern or pass a path\.\]\z/, many)
    assert_operator many.bytesize, :<, 20_500
  end

  def test_grep_advises_a_higher_head_limit_only_below_its_cap
    @workspace.write("rows.txt", "r\n" * 300)

    below = @tools["grep"].call({ "pattern" => "r", "head_limit" => 199 })
    at_cap = @tools["grep"].call({ "pattern" => "r", "head_limit" => 1_000 })

    assert_match(/\[300 matches in all, 199 shown\. Narrow the pattern or raise head_limit\.\]\z/,
                 below)
    assert_match(/\[300 matches in all, 200 shown\. Narrow the pattern\.\]\z/, at_cap)
  end

  def test_grep_cuts_a_block_too_large_to_show_and_stops_after_its_bytes
    @workspace.write("a-wide.md", "#{"w" * 1_900} mark\n" * 30)
    @workspace.write("b-large.md", "#{"x" * 100_000}\n" * 51)
    @workspace.write("c-last.md", "needle\n")
    grep = @tools["grep"]

    wide = grep.call({ "pattern" => "mark", "path" => "a-wide.md", "context" => 10 })
    stopped = grep.call({ "pattern" => "needle" })
    whole = grep.call({ "pattern" => "^x", "path" => "b-large.md", "output_mode" => "count" })

    assert_match(/\n\[cut at 20000 bytes\]/, wide)
    assert_equal "No matches.\n[The search stopped after 5000000 bytes. Pass a path to search " \
                 "the rest.]", stopped
    assert_equal "51 matches in 51 lines", whole
  end

  def test_grep_counts_every_match_and_keeps_only_those_it_shows
    @workspace.write("wide.txt", "x" * 200_000)
    grep = @tools["grep"]

    count = grep.call({ "pattern" => ".", "path" => "wide.txt", "output_mode" => "count" })
    shown = grep.call({ "pattern" => "x", "path" => "wide.txt", "head_limit" => 3 })

    assert_equal "200000 matches in 1 lines", count
    assert_equal 3, shown.scan("[character ").length
    assert_match(/\[200000 matches in all, 3 shown\./, shown)
  end

  def test_grep_answers_a_pattern_it_cannot_use_as_an_error
    reply = @tools["grep"].call({ "pattern" => "(" })

    assert_predicate reply, :error?
    assert_match(/The pattern could not be used/, reply.content)
  end
end
