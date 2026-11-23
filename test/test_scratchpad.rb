# frozen_string_literal: true

require_relative "test_helper"

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

    assert_match(%r{\Ascratchpad/tool-results/\d{8}T\d{6}-export\.txt\z}, text.cut["path"])
    assert_equal ROWS, @workspace.read(text.cut["path"])
    assert_equal 330_000, text.cut["bytes"]
    assert_operator text.text.bytesize, :<, 2_400
    assert_match(/is 330000 bytes in 10000 lines.*saved at #{text.cut["path"]}.*read_file.*grep/,
                 text.text.lines.last)
    assert json.cut["path"].end_with?("-search.json")
    offered = provider.requests.first[:options][:tools].map { |tool| tool[:name] }

    assert_includes offered, "read_file"
  end

  def test_the_model_is_told_once_and_again_with_a_listing_when_the_note_is_gone
    agent, = agent_for([{ name: "export" }])

    agent.run("go")
    notes = agent.session.messages.select { |message| message.reminder == "scratchpad" }

    assert_equal 1, notes.length
    refute_includes notes.first.text, "It holds"
    assert_match(%r{It holds:\nscratchpad/tool-results/.*-export\.txt \(330000 bytes\)},
                 Mistri::Scratchpad.new(@workspace).note)
  end

  def test_a_document_tool_reads_a_saved_result_without_saving_another
    @workspace.write("scratchpad/tool-results/saved.txt", ROWS)
    read_saved = { name: "read_file", arguments: { path: "scratchpad/tool-results/saved.txt" } }
    limit = Mistri::ResultLimit.new(bytes: 4_000, turn_bytes: 4_000)
    agent, = agent_for([read_saved, read_saved], result_limit: limit)

    agent.run("go")
    reads = agent.session.messages.select(&:tool?)

    assert(reads.all? { |read| read.cut && read.cut["path"].nil? })
    assert_equal ["scratchpad/tool-results/saved.txt"], @workspace.list
    assert_match(/share one limit.*not kept/, reads.first.text.lines.last)
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
    pad = Mistri::Scratchpad.new(@workspace)

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

  def test_the_folder_of_saved_results_is_read_only_to_the_model
    tools = Mistri::Tools.files(@workspace).to_h { |tool| [tool.name, tool] }
    @workspace.write("scratchpad/tool-results/saved.txt", "kept")
    path = "scratchpad/tool-results/saved.txt"

    edit = { "path" => path, "old_string" => "kept", "new_string" => "x" }
    replies = [tools["write_file"].call({ "path" => path, "content" => "x" }),
               tools["edit_file"].call(edit), tools["delete_file"].call({ "path" => path })]
    note = tools["write_file"].call({ "path" => "scratchpad/notes.md", "content" => "mine" })

    capitals = tools["delete_file"].call({ "path" => "Scratchpad/Tool-Results/saved.txt" })

    assert(replies.all? { |reply| reply.error? && reply.content.include?("read-only") })
    assert_includes capitals.content, "read-only"
    assert_equal "kept", @workspace.read(path)
    assert_match(%r{\AWrote scratchpad/notes\.md}, note)
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
