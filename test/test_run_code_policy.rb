# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/scripted_sandbox"

# A call from code passes what a call from the model passes: the tool's
# timeout, the hooks, the approval rule and the host's own tools.
class TestRunCodePolicy < Minitest::Test
  include Mistri::Test::ScriptedRuns

  def setup
    @workspace = Mistri::Workspace::Memory.new
    @workspace.write("scratchpad/notes.md", "old")
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
    agent = Mistri::Agent.new(provider:, tools: [ask], sandbox: Mistri::Test::ScriptedSandbox.new)

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
    agent = Mistri::Agent.new(provider:, tools: [slow], sandbox: Mistri::Test::ScriptedSandbox.new)
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
    agent = Mistri::Agent.new(provider:, tools: [lookup], sandbox: Mistri::Test::ScriptedSandbox.new,
                              after_tool: hide)

    agent.run("go")

    assert_equal %(printed\n["Ana, card [hidden]"]), agent.session.messages.find(&:tool?).text
  end

  def test_a_write_from_code_shows_a_hook_its_content_and_stores_a_short_copy
    seen = []
    watch = lambda do |call, _context|
      seen << call.arguments["content"] if call.name == "write_file"
      "no tables are dropped" if call.arguments["content"].to_s.include?("DROP")
    end
    plan = "a step of the plan\n" * 500
    replies, agent = answers([["write", { "path" => "scratchpad/a.md", "content" => plan }],
                              ["write",
                               { "path" => "scratchpad/b.md", "content" => "DROP TABLE" }]],
                             scratchpad: @workspace, before_tool: watch)
    stored = agent.session.entries.select { |entry| entry["type"] == "code_call" }

    assert_equal [plan, "DROP TABLE"], seen
    assert_match(/Blocked: no tables are dropped/, replies[1])
    assert_nil @workspace.read("scratchpad/b.md")
    assert_equal plan, @workspace.read("scratchpad/a.md")
    assert_equal "scratchpad/a.md", stored[0].dig("call", "arguments", "path")
    assert_match(/\A(a step of the plan\n)+a step.*\n\[cut at \d+ of 9500 bytes\]\z/,
                 stored[0].dig("call", "arguments", "content"))
    assert_equal "DROP TABLE", stored[1].dig("call", "arguments", "content")
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

  def test_a_subscribers_failure_on_a_call_from_code_reaches_the_caller
    lookup = Mistri::Tool.define("lookup", "Looks up.") { "found" }
    script = [["tool", { "name" => "lookup", "arguments" => {} }]]
    calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [lookup], sandbox: Mistri::Test::ScriptedSandbox.new)

    error = assert_raises(IOError) do
      agent.run("go") do |event|
        raise IOError, "the socket closed" if event.tool_call&.name == "lookup"
      end
    end

    assert_equal "the socket closed", error.message
  end

  def test_code_cannot_load_a_tool_for_the_model
    hidden = Mistri::Tool.define("lookup", "Looks up a customer.", deferred: true) { "found" }
    search = { "name" => "tool_search", "arguments" => { "query" => "select:lookup" } }

    replies, agent = answers([["tool", search]], tools: [hidden])

    assert_match(/tool_search loads tools into your own list, so code cannot make it/, replies[0])
    assert(agent.session.messages.none?(&:loads))
  end

  def test_an_approval_rule_that_raises_answers_the_code
    risky = Mistri::Tool.define("risky", "Does something.",
                                needs_approval: lambda { |_arguments|
                                  raise "the rule is broken"
                                }) { "ran" }

    replies, = answers([["tool", { "name" => "risky", "arguments" => {} }]], tools: [risky])

    assert_match(/Error evaluating approval policy for tool "risky": RuntimeError/, replies[0])
  end
end
