# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/scripted_sandbox"

# run_code: what code in a sandbox asks for passes the same contract, hooks
# and events as a call from the model, and is stored beside the messages.
class TestRunCode < Minitest::Test
  include Mistri::Test::ScriptedRuns

  def setup
    @workspace = Mistri::Workspace::Memory.new
    @workspace.write("scratchpad/notes.md", "old")
    @sent = []
  end

  def test_code_calls_a_tool_and_reads_and_writes_documents
    search = ["tool", { "name" => "search", "arguments" => { "status" => "open" } }]
    agent, events = run_code([search,
                              ["read", { "path" => "scratchpad/notes.md" }],
                              ["write", { "path" => "scratchpad/notes.md", "content" => "new" }],
                              ["list", { "prefix" => "scratchpad/" }]])
    result = agent.session.messages.find(&:tool?)
    stored = agent.session.entries.select { |entry| entry["type"] == "code_call" }

    assert_equal %(printed\n["3 open orders","old",null,["scratchpad/notes.md"]]), result.text
    assert_equal "new", @workspace.read("scratchpad/notes.md")
    assert_equal(%w[search read_file write_file list_files],
                 stored.map { |entry| entry.dig("call", "name") })
    assert_equal "new", stored[2].dig("call", "arguments", "content")
    assert_equal %w[before:run_code started:run_code before:search started:search result:search
                    before:read_file started:read_file result:read_file before:write_file
                    started:write_file result:write_file before:list_files started:list_files
                    result:list_files result:run_code], events
  end

  def test_code_cannot_make_a_call_that_needs_approval_or_one_a_hook_blocks
    agent, = run_code([["tool", { "name" => "issue_refund", "arguments" => {} }],
                       ["tool", { "name" => "search", "arguments" => { "status" => "blocked" } }],
                       ["tool", { "name" => "search", "arguments" => { "status" => 7 } }],
                       ["tool", { "name" => "run_code", "arguments" => { "code" => "[]" } }]])
    answers = JSON.parse(agent.session.messages.find(&:tool?).text.lines.last)

    assert_empty @sent
    assert_match(/needs a person's approval.*Call the tool yourself/, answers[0])
    assert_match(/Blocked: no blocked orders/, answers[1])
    assert_match(/threw: Invalid arguments.*status must be string/m, answers[2])
    assert_match(/run_code cannot be called from code/, answers[3])
  end

  def test_the_entry_of_a_call_from_code_keeps_a_short_copy_of_its_result
    rows = Mistri::Tool.define("rows", "Returns rows.") { "order 1001 shipped\n" * 2_000 }
    script = [["tool", { "name" => "rows", "arguments" => {} }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [rows], sandbox: Mistri::Test::ScriptedSandbox.new)

    agent.run("go")
    stored = agent.session.entries.find { |entry| entry["type"] == "code_call" }.fetch("message")

    assert_operator agent.session.messages.find(&:tool?).cut["bytes"], :>, 38_000
    assert_operator stored.dig("content", 0, "text").bytesize, :<=, 2_000
    assert_equal 38_000, stored.dig("cut", "bytes")
  end

  def test_the_entry_of_a_call_from_code_keeps_a_short_copy_of_its_arguments
    given = nil
    save = Mistri::Tool.define("save_rows", "Saves rows.", schema: lambda {
      string :region, "Region", required: true
      string :note, "A note", required: true
      array :rows, "Rows", required: true, items: { type: "object" }
    }) do |arguments|
      given = arguments
      "saved"
    end
    arguments = { "note" => "n" * 3_000, "rows" => Array.new(200) { |n| { "id" => n } },
                  "region" => "emea" }

    _replies, agent = answers([["tool", { "name" => "save_rows", "arguments" => arguments }]],
                              tools: [save])
    stored = agent.session.entries.find { |entry| entry["type"] == "code_call" }
                  .dig("call", "arguments")

    assert_equal arguments, given
    assert_equal %w[note rows region], stored.keys
    assert_equal "emea", stored["region"]
    assert_match(/\An+\n\[cut at \d+ of 3000 bytes\]\z/, stored["note"])
    assert_match(/\A\[\d+ bytes of JSON\]\z/, stored["rows"])
    assert_operator JSON.generate(stored).bytesize, :<, 2_200
  end

  def test_code_is_refused_what_the_agent_does_not_have
    replies, = answers([["bogus", {}],
                        ["write", { "path" => "scratchpad/a.md", "content" => "x" }],
                        ["read", { "path" => "../secret" }],
                        ["read", { "path" => "scratchpad/missing.md" }],
                        ["list", {}]],
                       tools: [Mistri::Tools.read_file(@workspace),
                               Mistri::Tools.list_files(@workspace)])

    assert_match(/the code asked for bogus, which does not exist/, replies[0])
    assert_match(/you do not have the write_file tool/, replies[1])
    assert_match(/is not a path here/, replies[2])
    assert_match(/No document at/, replies[3])
    assert_equal ["scratchpad/notes.md"], replies[4]
  end

  def test_an_empty_path_from_code_is_refused_except_to_list_every_document
    replies, = answers([["read", { "path" => "" }],
                        ["write", { "path" => "", "content" => "x" }],
                        ["delete", { "path" => "" }],
                        ["list", { "prefix" => "" }]], files: @workspace)

    replies.first(3).each { |reply| assert_match(/"" is not a path here: it is empty/, reply) }
    assert_equal ["scratchpad/notes.md"], replies[3]
    assert_equal ["scratchpad/notes.md"], @workspace.list
  end

  def test_code_is_refused_a_document_that_is_not_text
    @workspace.write("logo.png", "\x89PNG\xFF".dup.force_encoding(Encoding::UTF_8))

    replies, = answers([["read", { "path" => "logo.png" }]], files: @workspace)

    assert_equal ["threw: logo.png is not text, so code cannot read it"], replies
  end

  def test_the_entry_of_a_call_from_code_is_a_short_copy_where_no_limit_is_in_force
    rows = Mistri::Tool.define("rows", "Returns rows.") do
      Mistri::ToolResult.new(content: [Mistri::Content::Text.new(text: "order\n" * 1_000)])
    end
    script = [["tool", { "name" => "rows", "arguments" => {} }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [rows], sandbox: Mistri::Test::ScriptedSandbox.new,
                              result_limit: false)
    shown = []

    agent.run("go") { |event| shown << event.content if event.tool_call&.name == "rows" }
    stored = agent.session.entries.find { |entry| entry["type"] == "code_call" }.fetch("message")

    assert_operator stored["content"].sum { |block| block["text"].bytesize }, :<=, 2_000
    assert_equal 6_000, stored.dig("cut", "bytes")
    assert_equal "[content]", shown.last
    assert_nil agent.session.messages.find(&:tool?).cut
  end

  def test_a_write_from_code_loses_to_a_writer_that_got_there_first
    @workspace.define_singleton_method(:compare_and_write) do |*, **|
      raise Mistri::WorkspaceConflictError, "another writer got there first"
    end

    replies, = answers([["read", { "path" => "scratchpad/notes.md" }],
                        ["write", { "path" => "scratchpad/notes.md", "content" => "mine" }]],
                       scratchpad: @workspace)

    assert_match(/changed since\. Read it in this code before writing it/, replies[1])
    assert_equal "old", @workspace.read("scratchpad/notes.md")
  end

  def test_code_writes_over_a_document_only_after_reading_it
    agent, = run_code([["write", { "path" => "scratchpad/notes.md", "content" => "blind" }],
                       ["write", { "path" => "scratchpad/tool-results/x.txt", "content" => "x" }],
                       ["delete", { "path" => "scratchpad/missing.md" }]])
    answers = JSON.parse(agent.session.messages.find(&:tool?).text.lines.last)

    assert_equal "old", @workspace.read("scratchpad/notes.md")
    assert_match(/has not read/, answers[0])
    assert_match(/read-only/, answers[1])
    assert_match(/No document/, answers[2])
  end

  def test_code_makes_no_call_after_the_run_is_stopped
    signal = Mistri::AbortSignal.new
    searched = []
    halt = Mistri::Tool.define("halt", "Stops the run.") do
      signal.abort!
      "stopping"
    end
    search = Mistri::Tool.define("search", "Searches orders.") do
      searched << true
      "3 open orders"
    end
    script = [["tool", { "name" => "halt", "arguments" => {} }],
              ["tool", { "name" => "search", "arguments" => {} }],
              ["read", { "path" => "scratchpad/notes.md" }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [halt, search], scratchpad: @workspace,
                              sandbox: Mistri::Test::ScriptedSandbox.new)

    agent.run("go", signal:)
    stored = agent.session.entries.select { |entry| entry["type"] == "code_call" }

    assert_empty searched
    assert_equal(["halt"], stored.map { |entry| entry.dig("call", "name") })
  end

  def test_an_agent_without_a_sandbox_has_no_run_code
    provider = Mistri::Providers::Fake.new(turns: [{ text: "done" }])
    Mistri::Agent.new(provider:, scratchpad: @workspace).run("go")

    refute_includes provider.requests.first[:options][:tools].map { |tool| tool[:name] }, "run_code"
  end

  private

  def run_code(script)
    search = Mistri::Tool.define("search", "Searches orders.",
                                 schema: -> { string :status, "Status" }) { "3 open orders" }
    refund = Mistri::Tool.define("issue_refund", "Refunds an order.", needs_approval: true) do
      @sent << true
      "sent"
    end
    events = []
    block = lambda do |call, _context|
      events << "before:#{call.name}"
      "no blocked orders" if call.arguments["status"] == "blocked"
    end
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [search, refund], scratchpad: @workspace,
                              sandbox: Mistri::Test::ScriptedSandbox.new, before_tool: block)
    agent.run("go") do |event|
      events << "started:#{event.tool_call.name}" if event.type == :tool_started
      events << "result:#{event.tool_call.name}" if event.type == :tool_result
    end
    [agent, events]
  end
end
