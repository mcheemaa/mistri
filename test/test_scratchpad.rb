# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/plain_workspace"

# With a scratchpad the whole of a result over its limit is saved, and the
# model is shown its start and where the rest is.
class TestScratchpad < Minitest::Test
  ROW = "order 1001 shipped to a customer\n"
  ROWS = ROW * 10_000

  def setup
    @workspace = Mistri::Workspace::Memory.new
  end

  def test_a_large_result_is_saved_whole_and_stored_as_its_start
    agent, provider = agent_for([{ name: "export" }, { name: "search" }])

    agent.run("go")
    text, json = agent.session.messages.select(&:tool?)

    assert_match(%r{\Ascratchpad/tool-results/\d{8}T\d{6}-export-\h{8}\.txt\z}, text.cut["path"])
    assert_equal ROWS, @workspace.read(text.cut["path"])
    assert_equal 330_000, text.cut["bytes"]
    assert_operator text.text.bytesize, :<, 2_400
    assert_match(/is 330000 bytes in 10000 lines.*saved at #{text.cut["path"]}.*read_file.*grep/,
                 text.text.lines.last)
    assert_match(/-search-\h{8}\.json\z/, json.cut["path"])
    offered = provider.requests.first[:options][:tools].map { |tool| tool[:name] }

    assert_includes offered, "read_file"
  end

  def test_the_model_is_told_once_and_again_with_a_listing_when_the_note_is_gone
    agent, = agent_for([{ name: "export" }])

    agent.run("go")
    notes = agent.session.messages.select { |message| message.reminder == "scratchpad" }

    assert_equal 1, notes.length
    refute_includes notes.first.text, "It holds"
    assert_match(%r{It holds:\nscratchpad/tool-results/.*-export-\h{8}\.txt \(330000 bytes\)},
                 Mistri.const_get(:Scratchpad, false).new(@workspace).note)
  end

  def test_parts_of_a_saved_result_read_together_fit_their_share_and_save_no_other
    @workspace.write("scratchpad/tool-results/saved.txt", ROWS)
    read_saved = { name: "read_file", arguments: { path: "scratchpad/tool-results/saved.txt" } }
    limit = Mistri::ResultLimit.new(bytes: 4_000, turn_bytes: 4_000)
    agent, = agent_for([read_saved, read_saved], result_limit: limit)

    agent.run("go")
    reads = agent.session.messages.select(&:tool?)

    assert reads.none?(&:cut)
    assert(reads.all? { |read| read.text.match?(/Continue with offset \d+\.\]\z/) })
    assert_equal ["scratchpad/tool-results/saved.txt"], @workspace.list
  end

  def test_a_result_that_fits_stays_whole_beside_results_that_are_saved
    summary = Mistri::Tool.define("summary", "A summary.") { ROW * 1_300 }
    calls = Array.new(4) { { name: "export" } } + [{ name: "summary" }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    export = Mistri::Tool.define("export", "Exports rows.") { ROWS }
    agent = Mistri::Agent.new(provider:, tools: [export, summary], scratchpad: @workspace)

    agent.run("go")
    results = agent.session.messages.select(&:tool?)

    assert(results.first(4).all? { |result| result.cut["path"] })
    assert_nil results.last.cut
    assert_equal ROW * 1_300, results.last.text
  end

  def test_the_largest_result_is_saved_and_the_others_that_fit_stay_whole
    lines = -> { integer :lines, "Lines" }
    page = Mistri::Tool.define("page", "A page.", schema: lines) { |given| ROW * given["lines"] }
    never = Mistri::Tool.define("feed", "The feed.", save_result: false) { ROW * 1_400 }
    calls = [1_364, 1_361, 1_363, 1_362].map { |lines| { name: "page", arguments: { lines: } } }
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls + [{ name: "feed" }] },
                                                   { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [page, never], scratchpad: @workspace)

    agent.run("go")
    pages = agent.session.messages.select(&:tool?)

    assert_equal([true, false, false, false, false], pages.map { |result| !result.cut.nil? })
    assert_equal ROW * 1_364, @workspace.read(pages.first.cut["path"])
    assert_operator pages.sum { |result| result.text.bytesize }, :<=, 200_000
  end

  def test_a_tool_that_is_never_saved_is_cut
    feed = Mistri::Tool.define("feed", "The feed.", save_result: false) { ROWS }
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: [{ name: "feed" }] },
                                                   { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [feed], scratchpad: @workspace)

    agent.run("go")
    result = agent.session.messages.find(&:tool?)

    assert_nil result.cut["path"]
    assert_match(/The rest was not kept/, result.text.lines.last)
    assert_empty @workspace.list
  end

  def test_a_result_the_scratchpad_cannot_take_is_cut_and_says_so
    @workspace.define_singleton_method(:compare_and_write) { |*, **| raise IOError, "disk full" }
    agent, = agent_for([{ name: "export" }])

    _out, err = capture_io { agent.run("go") }
    stored = agent.session.messages.find(&:tool?)

    assert_nil stored.cut["path"]
    assert_match(/could not be saved, so the rest was not kept/, stored.text.lines.last)
    assert_match(/saving a result of export failed \(IOError: disk full\)/, err)
  end

  def test_two_results_in_one_second_get_two_documents
    agent, = agent_for([{ name: "export" }, { name: "export" }])

    agent.run("go")
    paths = agent.session.messages.select(&:tool?).map { |message| message.cut["path"] }

    assert_equal 2, paths.uniq.length
    assert_equal paths.sort, @workspace.list
  end

  def test_every_result_of_a_crowded_second_gets_a_document
    pad = Mistri.const_get(:Scratchpad, false).new(@workspace)

    paths = Array.new(12) { pad.save_result(ROW, "fetch") }

    assert_equal 12, paths.uniq.length
    assert_equal paths.sort, @workspace.list.sort
  end

  def test_a_result_of_text_blocks_is_saved_as_its_text
    blocks = Mistri::Tool.define("blocks", "Returns text blocks.") do
      Mistri::ToolResult.new(content: [Mistri::Content::Text.new(text: ROWS),
                                       Mistri::Content::Text.new(text: "the end")])
    end
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: [{ name: "blocks" }] },
                                                   { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [blocks], scratchpad: @workspace)

    agent.run("go")
    stored = agent.session.messages.find(&:tool?)

    assert_equal "#{ROWS}\nthe end", @workspace.read(stored.cut["path"])
  end

  def test_a_workspace_with_no_conditional_write_saves_in_two_steps
    plain = Mistri::Test::PlainWorkspace.new
    refusing = Mistri::Workspace::Memory.new
    refusing.define_singleton_method(:compare_and_write) do |*, **|
      raise Mistri::ConfigurationError, "inside a transaction the host opened"
    end
    pad = Mistri.const_get(:Scratchpad, false)

    paths = Array.new(12) { pad.new(plain).save_result(ROW, "fetch") }
    refused = pad.new(refusing).save_result("{not json", "search")

    assert_equal paths.uniq.sort, plain.list
    assert_match(%r{It holds:\n(scratchpad/tool-results/\S+-fetch-\h{8}\.txt\n?){12}\z},
                 pad.new(plain).note)
    assert_equal "{not json", refusing.read(refused)
    assert_match(/-search-\h{8}\.txt\z/, refused)
  end

  def test_agents_that_share_a_scratchpad_with_no_conditional_write_save_under_their_own_names
    slow = Class.new(Mistri::Test::PlainWorkspace) do
      def read(path) = super.tap { sleep 0.01 }
    end.new
    pad = Mistri.const_get(:Scratchpad, false)

    saved = Array.new(8) do |number|
      Thread.new { [number, pad.new(slow).save_result("result #{number}", "fetch")] }
    end.map(&:value)

    assert_equal 8, saved.map(&:last).uniq.length
    saved.each { |number, path| assert_equal "result #{number}", slow.read(path) }
  end

  def test_a_result_whose_name_is_taken_is_not_saved
    taken = Mistri::Workspace::Memory.new
    taken.define_singleton_method(:compare_and_write) do |*, **|
      raise Mistri::WorkspaceConflictError, "taken"
    end

    error = assert_raises(Mistri::Error) do
      Mistri.const_get(:Scratchpad, false).new(taken).save_result(ROW, "fetch")
    end

    assert_match(%r{\Ascratchpad/tool-results/\S+-fetch-\h{8}\.txt is taken\z}, error.message)
  end

  def test_the_note_lists_as_many_documents_as_fit
    300.times { |number| @workspace.write("scratchpad/notes/#{"n" * 40}-#{number}.md", "x") }

    note = Mistri.const_get(:Scratchpad, false).new(@workspace).note

    assert_operator note.bytesize, :<, 5_000
    assert_match(/\[\d+ more\. Use list_files\.\]\z/, note)
  end

  def test_the_folder_of_saved_results_is_read_only_to_the_model
    tools = Mistri::Tools.files(@workspace).to_h { |tool| [tool.name, tool] }
    @workspace.write("scratchpad/tool-results/saved.txt", "kept")
    path = "scratchpad/tool-results/saved.txt"

    edit = { "path" => path, "old_string" => "kept", "new_string" => "x" }
    replies = [tools["write_file"].call({ "path" => path, "content" => "x" }),
               tools["edit_file"].call(edit), tools["delete_file"].call({ "path" => path })]
    note = tools["write_file"].call({ "path" => "scratchpad/notes.md", "content" => "mine" })

    assert(replies.all? { |reply| reply.error? && reply.content.include?("read-only") })
    assert_equal "kept", @workspace.read(path)
    assert_match(%r{\AWrote scratchpad/notes\.md}, note)
  end

  def test_a_path_that_a_store_may_match_to_the_folder_of_saved_results_is_read_only_too
    tools = Mistri::Tools.files(@workspace).to_h { |tool| [tool.name, tool] }
    paths = ["Scratchpad/Tool-Results/saved.txt", "scratchpad/tool-r\u00E9sults/saved.txt",
             "scratchpad/tool-re\u017Fults/saved.txt", "scr\u00E0tchpad/tool-results/saved.txt",
             "scratchpad/tool-results"]

    replies = paths.flat_map do |path|
      [tools["write_file"].call({ "path" => path, "content" => "x" }),
       tools["delete_file"].call({ "path" => path })]
    end
    beside = tools["write_file"].call({ "path" => "scratchpad/tool-results.md", "content" => "x" })
    folder = tools["write_file"].call({ "path" => "Scratchpad", "content" => "x" })

    assert_match(/\Ascratchpad is a folder, so no document can have that path\./, folder.content)
    assert(replies.all? { |reply| reply.error? && reply.content.include?("read-only") })
    assert_match(%r{\AWrote scratchpad/tool-results\.md}, beside)
  end

  def test_a_tools_own_limit_stands_in_for_the_agents
    guide = Mistri::Tool.define("guide", "The guide.", result_limit: 100_000) { ROW * 2_000 }
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: [{ name: "guide" }] },
                                                   { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [guide], scratchpad: @workspace,
                              result_limit: Mistri::ResultLimit.new(bytes: 4_000))

    agent.run("go")

    assert_equal ROW * 2_000, agent.session.messages.find(&:tool?).text
    assert_empty @workspace.list
  end

  private

  def agent_for(calls, **)
    export = Mistri::Tool.define("export", "Exports rows.") { ROWS }
    search = Mistri::Tool.define("search", "Searches.") do
      JSON.generate(Array.new(4_000) { |id| { id:, name: "Customer #{id}" } })
    end
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    [Mistri::Agent.new(provider:, tools: [export, search], scratchpad: @workspace, **), provider]
  end
end
