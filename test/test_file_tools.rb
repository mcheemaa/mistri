# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/plain_workspace"

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
    assert_match(/\Ahero\.html, version \h{12}, lines 2-2 of 4:/, window)
    assert_includes window, "[2 more lines. Continue with offset 3.]"
  end

  def test_read_file_and_grep_give_the_offset_that_reads_into_a_long_line
    @workspace.write("rows.json", "short\nlines\n[#{"{\"id\":1}," * 1_000}{\"id\":\"last\"}]")
    lines = @tools["read_file"].call({ "path" => "rows.json" })
    on = @tools["read_file"].call({ "path" => "rows.json", "unit" => "characters",
                                    "offset" => 2_012, "limit" => 9 })
    found = @tools["grep"].call({ "pattern" => "last" })
    at = @tools["read_file"].call({ "path" => "rows.json", "unit" => "characters",
                                    "offset" => found[/character (\d+)/, 1].to_i, "limit" => 4 })

    assert_includes lines, "[line cut: 7015 more characters. Read on with unit characters and " \
                           "offset 2012.]"
    assert_match(/characters 2012-2021 of 9027:\n"id":1\},\{\n/, on)
    assert_match(/\Arows\.json:3: \[character 9020\] \.\.\./, found)
    assert_match(/characters 9020-9024 of 9027:\nlast\n/, at)
  end

  def test_a_part_that_is_read_fits_the_limit_in_force
    @workspace.write("notes/kanji.md", "#{"漢字のテキスト" * 12}\n" * 400)
    @workspace.write("notes/rows.md", "order 1001 shipped to a customer\n" * 2_000)
    read = lambda do |path, limit|
      calls = [{ name: "read_file", arguments: { path: } }]
      provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
      agent = Mistri::Agent.new(provider:, files: @workspace,
                                result_limit: Mistri::ResultLimit.new(bytes: limit))
      agent.run("go")
      agent.session.messages.find(&:tool?)
    end

    kanji = read.call("notes/kanji.md", 50_000)
    rows = read.call("notes/rows.md", 8_000)

    assert_nil kanji.cut
    assert_match(/lines 1-(\d+) of 400:.*\n\[\d+ more lines\. Continue with offset \d+\.\]\z/m,
                 kanji.text)
    assert_nil rows.cut
    assert_operator rows.text.bytesize, :<=, 8_000
    assert_match(/Continue with offset \d+\.\]\z/, rows.text)
  end

  def test_edit_file_rewrites_through_the_workspace
    reply = @tools["edit_file"].call({ "path" => "hero.html",
                                       "old_string" => "<h1>Welcome</h1>",
                                       "new_string" => "<h1>Hello</h1>" })

    assert_match(/\AReplaced 1 occurrence\(s\) in hero\.html, version \h{12}\z/, reply)
    assert_includes @workspace.read("hero.html"), "<h1>Hello</h1>"
  end

  def test_a_fuzzy_edit_preserves_the_following_line_in_storage
    reply = @tools["edit_file"].call({ "path" => "hero.html",
                                       "old_string" => "<h1>Welcome</h1>\n<p>Hi</p>",
                                       "new_string" => "  <h1>Hello</h1>\n  <p>Updated</p>" })

    assert_match(/\AReplaced 1 occurrence\(s\) in hero\.html, version \h{12}\z/, reply)
    assert_equal "<div>\n  <h1>Hello</h1>\n  <p>Updated</p>\n</div>\n",
                 @workspace.read("hero.html")
  end

  def test_edit_file_tolerates_alias_keys_and_stringly_booleans
    @workspace.write("x.txt", "a\na\n")
    reply = @tools["edit_file"].call({ "file" => "x.txt", "oldText" => "a",
                                       "newText" => "b", "replaceAll" => "true" })

    assert_match(/\AReplaced 2 occurrence\(s\) in x\.txt, version \h{12}\z/, reply)
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

    assert_predicate reply, :error?
    assert_match(/\Aedit_file failed:/, reply.content)
    assert_match(/Closest region/, reply.content)
  end

  def test_read_file_answers_an_empty_document_a_line_past_the_end_and_a_part_by_characters
    @workspace.write("empty.md", "")
    @workspace.write("kanji.md", "漢字のテキスト" * 5_000)
    read = @tools["read_file"]

    part = read.call({ "path" => "kanji.md", "unit" => "characters" })

    assert_match(/\Aempty\.md, version \h{12}, empty\.\z/, read.call({ "path" => "empty.md" }))
    assert_match(/4 lines\. Line 9 is past the end\.\z/,
                 read.call({ "path" => "hero.html", "offset" => 9 }))
    assert_match(/characters 0-6666 of 35000:/, part)
    assert_match(/\[28334 more characters\. Continue with offset 6666\.\]\z/, part)
  end

  def test_a_document_that_is_not_text_is_named_as_such_and_never_shown
    @workspace.write("logo.png", "\x89PNG\xFF".dup.force_encoding(Encoding::UTF_8))
    calls = [{ name: "read_file", arguments: { path: "logo.png" } },
             { name: "write_file", arguments: { path: "logo.png", content: "x" } },
             { name: "edit_file",
               arguments: { path: "logo.png", old_string: "PNG", new_string: "" } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, files: @workspace)

    agent.run("go")
    read, written, edited = agent.session.messages.select(&:tool?).map(&:text)

    assert_match(/\Alogo\.png, version \h{12}, 5 bytes that are not text\.\z/, read)
    assert_match(/The document now:\nlogo\.png, .* 5 bytes that are not text\.\z/, written)
    assert_equal "edit_file failed: logo.png is not text", edited
  end

  def test_a_path_too_long_or_not_text_is_refused
    replies = ["a" * 513, "caf\xE9.md".dup.force_encoding("UTF-8")].map do |path|
      @tools["read_file"].call({ "path" => path })
    end

    assert_match(/it is longer than 512 bytes/, replies[0].content)
    assert_match(/it is not valid UTF-8/, replies[1].content)
  end

  def test_a_workspace_with_four_methods_is_listed_and_written_in_two_steps
    plain = Mistri::Test::PlainWorkspace.new
    250.times { |number| plain.write("notes/#{number}.md", "x") }
    tools = Mistri::Tools.files(plain).to_h { |tool| [tool.name, tool] }

    listing = tools["list_files"].call({})
    written = tools["write_file"].call({ "path" => "new.md", "content" => "new" })
    blind = tools["write_file"].call({ "path" => "new.md", "content" => "again" })

    assert_match(%r{\Anotes/0\.md\n.*\n\[50 more not shown\. Pass a prefix to narrow\.\]\z}m,
                 listing)
    assert_match(/\AWrote new\.md/, written)
    assert_match(/holds a document already/, blind.content)
    assert_equal "new", plain.read("new.md")
  end

  def test_a_write_that_loses_to_another_writer_is_refused_with_the_document
    version = @tools["read_file"].call({ "path" => "hero.html" })[/version (\h{12})/, 1]
    @workspace.define_singleton_method(:compare_and_write) do |*, **|
      raise Mistri::WorkspaceConflictError, "another writer got there first"
    end

    refused = Mistri::Tools.write_file(@workspace).call(
      { "path" => "hero.html", "content" => "mine", "if_version" => version }
    )

    assert_match(/write_file refused: hero\.html is not at version #{version} any more/,
                 refused.content)
    assert_includes refused.content, "2:   <h1>Welcome</h1>"
  end

  def test_write_file_creates_and_lists_with_sizes
    reply = @tools["write_file"].call({ "path" => "notes/a.txt", "content" => "hello" })
    listing = @tools["list_files"].call({ "prefix" => "notes/" })

    assert_match(%r{\AWrote notes/a\.txt \(5 chars\), version \h{12}\z}, reply)
    assert_equal "notes/a.txt (5 bytes)", listing
  end

  def test_write_file_replaces_a_document_only_at_the_version_that_was_read
    version = @tools["read_file"].call({ "path" => "hero.html" })[/version (\h{12})/, 1]
    blind = @tools["write_file"].call({ "path" => "hero.html", "content" => "gone" })
    @workspace.write("hero.html", "<p>changed by another writer</p>\n")
    stale = @tools["write_file"].call({ "path" => "hero.html", "content" => "gone",
                                        "if_version" => version })
    current = stale.content.scan(/version (\h{12})/).last.first
    written = @tools["write_file"].call({ "path" => "hero.html", "content" => "new",
                                          "if_version" => current })

    assert_predicate blind, :error?
    assert_match(/holds a document already.*Nothing was written/, blind.content)
    assert_predicate stale, :error?
    assert_includes stale.content, "1: <p>changed by another writer</p>"
    assert_match(/\AWrote hero\.html/, written)
    assert_equal "new", @workspace.read("hero.html")
  end

  def test_write_file_takes_two_steps_where_the_workspace_cannot_take_one
    in_transaction = Class.new(Mistri::Workspace::Memory) do
      def snapshot(_path) = raise(Mistri::ConfigurationError, "cannot join an open transaction")
    end.new
    write = Mistri::Tools.write_file(in_transaction)

    created = write.call({ "path" => "a.txt", "content" => "one" })
    blind = write.call({ "path" => "a.txt", "content" => "two" })

    assert_match(/\AWrote a\.txt/, created)
    assert_predicate blind, :error?
    assert_equal "one", in_transaction.read("a.txt")
  end

  def test_delete_file_removes_a_document
    reply = @tools["delete_file"].call({ "path" => "hero.html" })
    again = @tools["delete_file"].call({ "path" => "hero.html" })

    assert_equal "Deleted hero.html", reply
    assert_nil @workspace.read("hero.html")
    assert_predicate again, :error?
  end

  def test_find_in_file_is_still_built_for_a_host_that_names_it
    reply = Mistri::Tools.find_in_file(@workspace).call({ "path" => "hero.html",
                                                          "query" => "Welcome" })

    assert_includes reply, "2:   <h1>Welcome</h1>"
  end

  def test_a_missing_document_is_an_actionable_error
    reply = @tools["read_file"].call({ "path" => "nope.html" })

    assert_predicate reply, :error?
    assert_match(/No document at "nope.html"/, reply.content)
  end

  def test_a_search_for_a_missing_document_is_an_actionable_error
    reply = @tools["grep"].call({ "path" => "nope.html", "pattern" => "title" })

    assert_predicate reply, :error?
    assert_match(/No document at or under "nope.html"/, reply.content)
  end

  def test_an_edit_to_a_missing_document_is_an_actionable_error
    reply = @tools["edit_file"].call({ "path" => "nope.html",
                                       "old_string" => "old", "new_string" => "new" })

    assert_predicate reply, :error?
    assert_match(/No document at "nope.html"/, reply.content)
  end

  def test_built_in_edit_failures_stay_typed_through_the_agent
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "edit_file",
                                                              arguments: {
                                                                path: "hero.html",
                                                                old_string: "missing",
                                                                new_string: "new"
                                                              } }] },
                                             { text: "recovered" }
                                           ])
    events = []
    agent = Mistri::Agent.new(provider:, tools: @tools.values)

    agent.run("edit it") { |event| events << event }

    event = events.find { |item| item.type == :tool_result }
    persisted = agent.session.messages.find(&:tool?)

    assert event.tool_error
    assert_predicate persisted, :tool_error?
    assert_match(/edit_file failed:/, persisted.text)
  end
end
