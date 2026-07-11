# frozen_string_literal: true

require_relative "test_helper"

class TestFileTools < Minitest::Test
  def setup
    @workspace = Mistri::Workspace::Memory.new
    @workspace.write("hero.html", "<div>\n  <h1>Welcome</h1>\n  <p>Hi</p>\n</div>\n")
    @tools = Mistri::Tools.files(@workspace).to_h { |tool| [tool.name, tool] }
  end

  def test_read_file_numbers_lines_and_windows
    full = @tools["read_file"].call({ "path" => "hero.html" })

    assert_includes full, "2:   <h1>Welcome</h1>"

    window = @tools["read_file"].call({ "path" => "hero.html", "offset" => 2, "limit" => 1 })

    assert_includes window, "2:   <h1>Welcome</h1>"
    refute_includes window, "3:"
    assert_includes window, "[showing lines 2-2 of 4]"
  end

  def test_edit_file_rewrites_through_the_workspace
    reply = @tools["edit_file"].call({ "path" => "hero.html",
                                       "old_string" => "<h1>Welcome</h1>",
                                       "new_string" => "<h1>Hello</h1>" })

    assert_equal "Replaced 1 occurrence(s) in hero.html", reply
    assert_includes @workspace.read("hero.html"), "<h1>Hello</h1>"
  end

  def test_edit_file_tolerates_alias_keys_and_stringly_booleans
    @workspace.write("x.txt", "a\na\n")
    reply = @tools["edit_file"].call({ "file" => "x.txt", "oldText" => "a",
                                       "newText" => "b", "replaceAll" => "true" })

    assert_equal "Replaced 2 occurrence(s) in x.txt", reply
    assert_equal "b\nb\n", @workspace.read("x.txt")
  end

  def test_edit_file_rejects_ambiguous_aliases
    error = assert_raises(ArgumentError) do
      @tools["edit_file"].call({ "file" => "x.txt", "path" => "y.txt",
                                 "oldText" => "a", "newText" => "b" })
    end

    assert_includes error.message, "map to \"path\""
  end

  def test_edit_file_failures_come_back_in_band_with_the_near_miss
    reply = @tools["edit_file"].call({ "path" => "hero.html",
                                       "old_string" => "<h1>Welcom</h1>",
                                       "new_string" => "x" })

    assert_match(/\Aedit_file failed:/, reply)
    assert_match(/Closest region/, reply)
  end

  def test_find_in_file_returns_numbered_matches_with_context
    reply = @tools["find_in_file"].call({ "path" => "hero.html", "query" => "Welcome",
                                          "context" => 1 })

    assert_includes reply, "1: <div>"
    assert_includes reply, "2:   <h1>Welcome</h1>"
    assert_includes reply, "3:   <p>Hi</p>"
  end

  def test_write_and_list_round_trip
    @tools["write_file"].call({ "path" => "notes/a.txt", "content" => "hello" })
    listing = @tools["list_files"].call({ "prefix" => "notes/" })

    assert_equal "notes/a.txt", listing
    assert_equal "hello", @workspace.read("notes/a.txt")
  end

  def test_a_missing_document_reads_as_guidance_not_an_error
    reply = @tools["read_file"].call({ "path" => "nope.html" })

    assert_match(/No document at "nope.html"/, reply)
  end
end
