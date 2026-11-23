# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/plain_workspace"

# The host's documents and the scratchpad in one path space, and a worker
# that shares the scratchpad with the agent that started it.
class TestPathSpace < Minitest::Test
  ROWS = "order 1001 shipped to a customer\n" * 10_000

  def setup
    @files = Mistri::Workspace::Memory.new
    @scratch = Mistri::Workspace::Memory.new
    @files.write("index.html", "<h1>Hi</h1>")
  end

  def test_a_path_under_scratchpad_is_the_scratchpads_and_any_other_the_hosts
    agent = agent_for([{ name: "export" },
                       { name: "write_file",
                         arguments: { path: "scratchpad/notes.md", content: "mine" } },
                       { name: "write_file", arguments: { path: "about.html", content: "new" } },
                       { name: "list_files" }])

    agent.run("go")
    listing = agent.session.messages.select(&:tool?).last.text

    assert_equal %w[about.html index.html], @files.list
    assert_equal 2, @scratch.list.length
    assert_equal "mine", @scratch.read("scratchpad/notes.md")
    assert_match(%r{\Aabout\.html \(3 bytes\)\nindex\.html \(11 bytes\)\nscratchpad/notes\.md},
                 listing)
    assert_match(%r{scratchpad/tool-results/.*-export\.txt \(330000 bytes\)\z}, listing)
  end

  def test_files_alone_gives_the_agent_the_document_tools
    provider = Mistri::Providers::Fake.new(turns: [{ text: "done" }])
    Mistri::Agent.new(provider:, files: @files).run("go")

    names = provider.requests.first[:options][:tools].map { |tool| tool[:name] }

    assert_equal %w[read_file write_file edit_file grep list_files delete_file], names
  end

  def test_a_path_that_is_not_plain_and_relative_is_refused_before_the_workspace
    tools = Mistri::Tools.files(@files).to_h { |tool| [tool.name, tool] }
    paths = ["/index.html", "./index.html", "notes/../index.html", "notes//a.md", "a\\b", ""]

    replies = paths.map { |path| tools["write_file"].call({ "path" => path, "content" => "x" }) }
    read = tools["read_file"].call({ "path" => "../secret" })
    listed = tools["list_files"].call({ "prefix" => "notes/" })

    assert(replies.all? { |reply| reply.error? && reply.content.include?("is not a path here") })
    assert_predicate read, :error?
    assert_equal "No documents found.", listed
    assert_equal ["index.html"], @files.list
  end

  def test_a_worker_shares_the_scratchpad_and_is_told_a_folder_of_its_own
    worker_turns = [{ tool_calls: [{ name: "write_file",
                                     arguments: { path: "scratchpad/agents/corgi/brand.md",
                                                  content: "blue" } }] },
                    { text: "See scratchpad/agents/corgi/brand.md." }]
    worker = Mistri::SubAgent.new(name: "research", description: "Researches a brand.",
                                  provider: Mistri::Providers::Fake.new(turns: worker_turns),
                                  scratchpad: @scratch)
    calls = [{ name: "research", arguments: { task: "Study the brand." } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    store = Mistri::Stores::Memory.new
    agent = Mistri::Agent.new(provider:, tools: [worker.tool], scratchpad: @scratch,
                              session: Mistri::Session.new(store:))

    agent.run("go")
    child = Mistri::Session.new(store:, id: agent.session.children.first.session_id)
    note = child.messages.find { |message| message.reminder == "scratchpad" }

    assert_equal "blue", @scratch.read("scratchpad/agents/corgi/brand.md")
    assert_match(%r{Write what you find under scratchpad/agents/research-\h{8}/ as you go},
                 note.text)
  end

  def test_a_worker_with_a_sandbox_runs_code_over_the_shared_scratchpad
    @scratch.write("scratchpad/tool-results/saved.txt", ROWS)
    sandbox = Class.new do
      def run(_code, host:)
        text = host.call("read", { "path" => "scratchpad/tool-results/saved.txt" })
        Mistri::Sandbox::Outcome.new(value: text.lines.length)
      end
    end.new
    worker_turns = [{ tool_calls: [{ name: "run_code", arguments: { code: "count" } }] },
                    { text: "10000 lines." }]
    worker = Mistri::SubAgent.new(name: "research", description: "Researches.",
                                  provider: Mistri::Providers::Fake.new(turns: worker_turns),
                                  scratchpad: @scratch, sandbox:)
    calls = [{ name: "research", arguments: { task: "Count the lines." } }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    store = Mistri::Stores::Memory.new
    agent = Mistri::Agent.new(provider:, tools: [worker.tool], session: Mistri::Session.new(store:))

    agent.run("go")
    child = Mistri::Session.new(store:, id: agent.session.children.first.session_id)

    assert_equal "10000", child.messages.find(&:tool?).text
    assert_equal "10000 lines.", agent.session.messages.find(&:tool?).text
  end

  def test_two_workspaces_with_no_sizes_are_listed_as_one
    files = Mistri::Test::PlainWorkspace.new
    scratch = Mistri::Test::PlainWorkspace.new
    space = Mistri::Workspace::PathSpace.new(files:, scratchpad: scratch)

    space.write("index.html", "<h1>Hi</h1>")
    space.write("scratchpad/notes.md", "mine")

    refute_respond_to space, :sizes
    assert_equal %w[index.html scratchpad/notes.md], space.list
    assert_equal ["scratchpad/notes.md"], scratch.list
    assert_equal "index.html\nscratchpad/notes.md", Mistri::Tools.list_files(space).call({})
  end

  def test_a_background_worker_granted_the_document_tools_shares_the_scratchpad
    dispatched = nil
    pool = Mistri::Tools.files(@scratch)
    spawn = Mistri::SubAgent.spawner(provider: Mistri::Providers::Fake.new(turns: []), tools: pool,
                                     dispatcher: ->(spec, _runner) { dispatched = spec },
                                     runtime_factory: ->(_spec) { raise "not run here" })
    arguments = { "name" => "Basset", "task" => "work", "instructions" => "Do the work.",
                  "mode" => "background", "tools" => %w[read_file write_file] }
    provider = Mistri::Providers::Fake.new(
      turns: [{ tool_calls: [{ name: "spawn_agent", arguments: }] }, { text: "done" }]
    )
    store = Mistri::Stores::Memory.new
    Mistri::Agent.new(provider:, tools: [spawn], session: Mistri::Session.new(store:)).run("go")
    write = { name: "write_file",
              arguments: { path: "scratchpad/agents/basset/found.md", content: "blue" } }
    factory = lambda do |spec|
      worker = Mistri::Providers::Fake.new(turns: [{ tool_calls: [write] }, { text: "done" }])
      granted = pool.select { |tool| spec.fetch("tool_names").include?(tool.name) }
      Mistri::SubAgent::Runtime.new(provider: worker, tools: granted, scratchpad: @scratch)
    end

    Mistri::SubAgent.run_dispatched(dispatched, store:, runtime_factory: factory)

    assert_equal "blue", @scratch.read("scratchpad/agents/basset/found.md")
  end

  def test_a_background_worker_with_a_scratchpad_needs_the_document_tools_granted
    dispatched = nil
    spawn = Mistri::SubAgent.spawner(provider: Mistri::Providers::Fake.new(turns: []),
                                     dispatcher: ->(spec, _runner) { dispatched = spec },
                                     runtime_factory: ->(_spec) { raise "not run here" })
    arguments = { "name" => "Basset", "task" => "work", "instructions" => "Do the work.",
                  "mode" => "background" }
    calls = [{ name: "spawn_agent", arguments: }]
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    store = Mistri::Stores::Memory.new
    Mistri::Agent.new(provider:, tools: [spawn], session: Mistri::Session.new(store:)).run("go")
    factory = lambda do |_spec|
      Mistri::SubAgent::Runtime.new(provider: Mistri::Providers::Fake.new(turns: []),
                                    scratchpad: @scratch)
    end

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.run_dispatched(dispatched, store:, runtime_factory: factory)
    end

    assert_match(/would add tools outside the durable grant/, error.message)
  end

  private

  def agent_for(calls)
    export = Mistri::Tool.define("export", "Exports rows.") { ROWS }
    provider = Mistri::Providers::Fake.new(turns: calls.map { |call| { tool_calls: [call] } } +
                                                  [{ text: "done" }])
    Mistri::Agent.new(provider:, tools: [export], files: @files, scratchpad: @scratch)
  end
end
