# frozen_string_literal: true

require_relative "test_helper"

# run_code: what code in a sandbox asks for passes the same contract, hooks
# and events as a call from the model, and is stored beside the messages.
class TestRunCode < Minitest::Test
  # Runs a script of host operations in place of JavaScript.
  class ScriptedSandbox
    def run(code, host:)
      value = JSON.parse(code).map do |operation, payload|
        host.call(operation, payload)
      rescue StandardError => e
        "threw: #{e.message}"
      end
      Mistri::Sandbox::Outcome.new(value:, output: ["printed"])
    end
  end

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
    assert_equal "[3 bytes]", stored[2].dig("call", "arguments", "content")
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

  def test_code_cannot_call_a_tool_that_ends_the_turn
    asked = []
    ask = Mistri::Tool.define("ask_user", "Asks the person.", ends_turn: true) do
      asked << true
      "asked"
    end
    script = [["tool", { "name" => "ask_user", "arguments" => {} }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [ask], sandbox: ScriptedSandbox.new)

    result = agent.run("go")

    assert_empty asked
    assert_match(/ask_user ends your turn, so code cannot make it/,
                 agent.session.messages.find(&:tool?).text)
    refute result.handed_off
  end

  def test_a_call_from_code_runs_under_the_tools_own_timeout
    slow = Mistri::Tool.define("slow", "Takes a while.", timeout: 0.05) do
      sleep 2
      "finished"
    end
    script = [["tool", { "name" => "slow", "arguments" => {} }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [slow], sandbox: ScriptedSandbox.new)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    agent.run("go")

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    assert_match(/Error running tool \\"slow\\": timed out after 0.05s/,
                 agent.session.messages.find(&:tool?).text)
  end

  def test_code_receives_what_after_tool_returned
    lookup = Mistri::Tool.define("lookup", "Looks up a customer.") { "Ana, card 4111" }
    hide = ->(call, _result, _context) { "Ana, card [hidden]" if call.name == "lookup" }
    script = [["tool", { "name" => "lookup", "arguments" => {} }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [lookup], sandbox: ScriptedSandbox.new,
                              after_tool: hide)

    agent.run("go")

    assert_equal %(printed\n["Ana, card [hidden]"]), agent.session.messages.find(&:tool?).text
  end

  def test_a_write_from_code_shows_a_hook_its_content_and_stores_only_its_size
    seen = []
    watch = lambda do |call, _context|
      seen << call.arguments["content"] if call.name == "write_file"
      "no tables are dropped" if call.arguments["content"].to_s.include?("DROP")
    end
    replies, agent = answers([["write", { "path" => "scratchpad/a.md", "content" => "plan" }],
                              ["write",
                               { "path" => "scratchpad/b.md", "content" => "DROP TABLE" }]],
                             scratchpad: @workspace, before_tool: watch)
    stored = agent.session.entries.select { |entry| entry["type"] == "code_call" }

    assert_equal ["plan", "DROP TABLE"], seen
    assert_match(/Blocked: no tables are dropped/, replies[1])
    assert_nil @workspace.read("scratchpad/b.md")
    assert_equal(["[4 bytes]", "[10 bytes]"],
                 stored.map { |entry| entry.dig("call", "arguments", "content") })
  end

  def test_code_reaches_a_hosts_own_document_tool_only_as_a_tool
    written = []
    schema = lambda do
      string :path, "Path", required: true
      string :content, "Content", required: true
    end
    own = Mistri::Tool.define("write_file", "Writes a document.", needs_approval: true,
                                                                  schema:) do |args|
      written << args
      "written"
    end
    arguments = { "path" => "scratchpad/a.md", "content" => "x" }
    replies, = answers([["write", arguments],
                        ["tool", { "name" => "write_file", "arguments" => arguments }],
                        ["read", { "path" => "scratchpad/notes.md" }]],
                       tools: [own, Mistri::Tools.read_file(@workspace)], scratchpad: @workspace)

    assert_empty written
    assert_match(/files.write is not available, because write_file here is the host's own tool/,
                 replies[0])
    assert_match(/needs a person's approval/, replies[1])
    assert_equal "old", replies[2]
  end

  def test_a_read_from_code_gives_after_tool_the_document
    hide = ->(call, result, _context) { result.sub("old", "[hidden]") if call.name == "read_file" }
    replies, agent = answers([["read", { "path" => "scratchpad/notes.md" }]],
                             scratchpad: @workspace, after_tool: hide)
    stored = agent.session.entries.find { |entry| entry["type"] == "code_call" }

    assert_equal ["[hidden]"], replies
    assert_equal "Read scratchpad/notes.md (8 bytes)", stored.dig("message", "content", 0, "text")
  end

  def test_the_entry_of_a_call_from_code_keeps_a_short_copy_of_its_result
    rows = Mistri::Tool.define("rows", "Returns rows.") { "order 1001 shipped\n" * 2_000 }
    script = [["tool", { "name" => "rows", "arguments" => {} }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [rows], sandbox: ScriptedSandbox.new)

    agent.run("go")
    stored = agent.session.entries.find { |entry| entry["type"] == "code_call" }.fetch("message")

    assert_operator agent.session.messages.find(&:tool?).cut["bytes"], :>, 38_000
    assert_operator stored.dig("content", 0, "text").bytesize, :<=, 2_000
    assert_equal 38_000, stored.dig("cut", "bytes")
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

  def test_after_tool_rewrites_what_a_list_a_write_and_a_delete_from_code_return
    hook = lambda do |call, _result, _context|
      case call.name
      when "list_files" then "only.md"
      when "write_file" then "noted"
      when "delete_file" then raise "the audit is down"
      end
    end
    replies, agent = answers([["list", { "prefix" => "scratchpad/" }],
                              ["write", { "path" => "scratchpad/n.md", "content" => "x" }],
                              ["delete", { "path" => "scratchpad/notes.md" }]],
                             scratchpad: @workspace, after_tool: hook)
    stored = agent.session.entries.select { |entry| entry["type"] == "code_call" }

    assert_equal ["only.md"], replies[0]
    assert_equal "noted", stored[1].dig("message", "content", 0, "text")
    assert_match(/Error in after_tool hook: RuntimeError: the audit is down/, replies[2])
    assert_nil @workspace.read("scratchpad/notes.md")
  end

  def test_a_call_from_code_is_stored_whole_where_no_limit_is_in_force
    rows = Mistri::Tool.define("rows", "Returns rows.") do
      Mistri::ToolResult.new(content: [Mistri::Content::Text.new(text: "order\n" * 1_000)])
    end
    script = [["tool", { "name" => "rows", "arguments" => {} }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [rows], sandbox: ScriptedSandbox.new,
                              result_limit: false)
    shown = []

    agent.run("go") { |event| shown << event.content if event.tool_call&.name == "rows" }
    stored = agent.session.entries.find { |entry| entry["type"] == "code_call" }.fetch("message")

    assert_equal 6_000, stored.dig("content", 0, "text").bytesize
    assert_nil stored["cut"]
    assert_equal "[content]", shown.last
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
                              sandbox: ScriptedSandbox.new)

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

  def answers(script, **)
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, sandbox: ScriptedSandbox.new, **)
    agent.run("go")
    [JSON.parse(agent.session.messages.find(&:tool?).text.lines.last), agent]
  end

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
                              sandbox: ScriptedSandbox.new, before_tool: block)
    agent.run("go") do |event|
      events << "started:#{event.tool_call.name}" if event.type == :tool_started
      events << "result:#{event.tool_call.name}" if event.type == :tool_result
    end
    [agent, events]
  end
end
