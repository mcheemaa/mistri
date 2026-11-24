# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/scripted_sandbox"

# The calls of one turn take effect in the order the model wrote them. A tool
# marked parallel runs together with its marked neighbours, and any other tool
# runs alone in its place.
class TestCallOrder < Minitest::Test
  def test_a_read_sees_the_write_sent_before_it
    document = +"old"
    write = Mistri::Tool.define("write", "Writes.") do
      sleep 0.05
      document.replace("new")
      "written"
    end
    read = Mistri::Tool.define("read", "Reads.", parallel: true) { document.dup }

    answers = answers_of(turn("write", "read"), [write, read])

    assert_equal %w[written new], answers.map(&:text)
  end

  def test_marked_calls_next_to_each_other_run_together
    started = { "left" => Queue.new, "right" => Queue.new }
    tools = { "left" => "right", "right" => "left" }.map do |name, other|
      Mistri::Tool.define(name, "Waits for the other.", parallel: true) do
        started[name] << true
        started[other].pop(timeout: 2) ? "together" : "alone"
      end
    end

    answers = answers_of(turn("left", "right"), tools)

    assert_equal %w[together together], answers.map(&:text)
  end

  def test_an_unmarked_call_runs_alone_in_its_place
    log = Queue.new
    tools = { "before" => true, "alone" => false, "after" => true }.map do |name, parallel|
      Mistri::Tool.define(name, "Logs.", parallel:) do
        log << "#{name} starts"
        sleep 0.03
        log << "#{name} ends"
        name
      end
    end

    answers_of(turn("before", "alone", "after"), tools)

    assert_equal ["before starts", "before ends", "alone starts", "alone ends",
                  "after starts", "after ends"], Array.new(log.size) { log.pop }
  end

  def test_one_call_runs_on_the_calling_thread
    thread = nil
    tool = Mistri::Tool.define("where", "Names its thread.") do
      thread = Thread.current
      "here"
    end

    answers_of(turn("where"), [tool])

    assert_same Thread.current, thread
  end

  def test_a_failed_call_stops_the_calls_after_it
    ran = []
    screened = []
    hooked = []
    started = []
    tools = [logging("first", ran), Mistri::Tool.define("broken", "Raises.") { raise "no" },
             logging("later", ran), logging("reader", ran, parallel: true)]
    provider = Mistri::Providers::Fake.new(turns: [turn("first", "broken", "later", "reader"),
                                                   { text: "done" }])
    after_tool = lambda do |call, _result, _context|
      hooked << call.name
      nil
    end
    before_tool = lambda do |call, _context|
      screened << call.name
      nil
    end
    agent = Mistri::Agent.new(provider:, tools:, before_tool:, after_tool:)

    agent.run("go") { |event| started << event.tool_call.name if event.type == :tool_started }
    answers = agent.session.messages.select(&:tool?)

    assert_equal %w[first], ran
    assert_equal %w[first broken later reader], screened
    assert_equal %w[first broken], started
    assert_equal %w[first broken], hooked
    assert_equal [false, true, true, true], answers.map(&:tool_error)
    assert_equal ["Not run: the broken call before this one failed."] * 2,
                 answers.last(2).map(&:text)
  end

  def test_each_way_a_call_does_not_take_effect_stops_the_call_after_it
    ran = []
    refusing = Mistri::Tool.define("refusing", "Returns an error.") do
      Mistri::ToolResult.new(content: "nothing to change", error: true)
    end
    strict = Mistri::Tool.define("strict", "Needs a count.",
                                 schema: -> { integer :count, "Count", required: true }) { "ok" }
    tools = [refusing, strict, logging("blocked", ran), logging("after", ran)]
    before_tool = ->(call, _context) { "not today" if call.name == "blocked" }

    %w[refusing strict blocked missing].each do |name|
      answers = answers_of(turn(name, "after"), tools, before_tool:)

      assert_equal "Not run: the #{name} call before this one failed.", answers.last.text
    end
    assert_empty ran
  end

  def test_a_marked_call_that_fails_or_is_refused_stops_nothing
    ran = []
    search = Mistri::Tool.define("search", "Raises.", parallel: true) { raise "offline" }
    lookup = Mistri::Tool.define("lookup", "Needs a query.",
                                 parallel: true,
                                 schema: -> { string :query, "Query", required: true }) { "ok" }

    answers = answers_of(turn("search", "write", "lookup", "write"),
                         [search, lookup, logging("write", ran)])

    assert_equal %w[write write], ran
    assert_equal [true, false, true, false], answers.map(&:tool_error)
  end

  def test_a_call_that_waits_for_a_person_holds_back_the_calls_after_it
    ran = []
    tools = [logging("lookup", ran), logging("send", ran, needs_approval: true),
             logging("read", ran, parallel: true), logging("pay", ran, needs_approval: true),
             logging("note", ran), logging("ship", ran, needs_approval: true)]
    provider = Mistri::Providers::Fake.new(
      turns: [turn("lookup", "send", "read", "pay", "note", "ship")]
    )
    agent = Mistri::Agent.new(provider:, tools:)

    result = agent.run("go")
    answers = agent.session.messages.select(&:tool?)

    assert_predicate result, :awaiting_approval?
    assert_equal %w[send pay], result.pending.map(&:name)
    assert_equal %w[lookup], ran
    assert_equal %w[lookup read note ship], answers.map(&:tool_name)
    assert_equal ["Not run: the send call before this one waits for a person's approval. " \
                  "Send this call again once it is decided."] * 3, answers.last(3).map(&:text)
    assert(answers.last(3).all?(&:tool_error?))
  end

  def test_a_read_written_after_a_write_that_waits_does_not_run_before_it
    document = +"old"
    write = Mistri::Tool.define("write", "Writes.", needs_approval: true) do
      document.replace("new")
      "written"
    end
    read = Mistri::Tool.define("read", "Reads.", parallel: true) { document.dup }
    provider = Mistri::Providers::Fake.new(turns: [turn("write", "read"), { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [write, read])
    agent.run("go").pending.each { |call| agent.session.approve(call.id) }

    agent.resume
    answers = agent.session.messages.select(&:tool?).to_h { |answer| [answer.tool_name, answer] }

    assert_equal "written", answers.fetch("write").text
    assert_includes answers.fetch("read").text, "Not run: the write call before this one waits"
  end

  def test_decided_calls_settle_in_the_order_written_and_only_a_failure_stops_the_rest
    ran = []
    failing = Mistri::Tool.define("charge", "Raises.", needs_approval: true) do
      ran << "charge"
      raise "declined"
    end
    tools = [logging("reserve", ran, needs_approval: true),
             logging("insure", ran, needs_approval: true), failing,
             logging("ship", ran, needs_approval: true)]
    provider = Mistri::Providers::Fake.new(turns: [turn("reserve", "insure", "charge", "ship"),
                                                   { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools:)
    agent.run("go").pending.each do |call|
      call.name == "insure" ? agent.session.deny(call.id) : agent.session.approve(call.id)
    end

    agent.resume
    answers = agent.session.messages.select(&:tool?).to_h { |answer| [answer.tool_name, answer] }

    assert_equal %w[reserve charge], ran
    refute_predicate answers.fetch("reserve"), :tool_error?
    assert_includes answers.fetch("charge").text, "declined"
    assert_equal "Not run: the charge call before this one failed.", answers.fetch("ship").text
    refute_includes answers.fetch("insure").text, "Not run"
  end

  def test_a_gated_call_after_a_failed_call_asks_no_one
    ran = []
    broken = Mistri::Tool.define("broken", "Raises.") { raise "no" }
    provider = Mistri::Providers::Fake.new(turns: [turn("broken", "send"), { text: "done" }])
    send = logging("send", ran, needs_approval: true)
    agent = Mistri::Agent.new(provider:, tools: [broken, send])

    result = agent.run("go")

    assert_predicate result, :completed?
    assert_empty agent.session.open_approvals
    assert_empty ran
    assert_equal "Not run: the broken call before this one failed.",
                 agent.session.messages.select(&:tool?).last.text
  end

  def test_the_gems_own_tools_are_marked_where_they_only_read_or_start_a_worker
    provider = Mistri::Providers::Fake.new
    memory = Struct.new(:read, :replace).new("", nil)
    tools = [*Mistri::Tools.files(Mistri::Workspace::Memory.new),
             Mistri::Tools.find_in_file(Mistri::Workspace::Memory.new),
             *Mistri::Tools.memory(memory),
             Mistri::Tools.run_code(Mistri::Test::ScriptedSandbox.new, limited: true) { nil },
             Mistri::Skills.reader([]), Mistri::ToolSearch.tool([], loaded: -> { [] }),
             Mistri::SubAgent.spawner(provider:), *Mistri::Console.tools,
             Mistri::SubAgent.new(name: "researcher", description: "Researches.", provider:).tool]

    marked, alone = tools.partition(&:parallel?).map { |group| group.map(&:name) }

    assert_equal %w[read_file grep list_files find_in_file read_memory read_skill tool_search
                    spawn_agent researcher], marked
    assert_equal %w[write_file edit_file delete_file update_memory run_code list_agents
                    read_agent steer_agent stop_agent], alone
  end

  def test_a_bridged_tool_is_marked_when_its_server_lists_it_as_read_only
    listed = [{ "name" => "snapshot", "annotations" => { "readOnlyHint" => true } },
              { "name" => "wait", "annotations" => { "readOnlyHint" => true } },
              { "name" => "click", "annotations" => { "readOnlyHint" => false } },
              { "name" => "type" }]
    client = Struct.new(:tools).new(listed)
    marks = ->(**options) { Mistri::MCP.tools(client, **options).map(&:parallel?) }

    assert_equal [true, true, false, false], marks.call
    assert_equal [false, false, false, false], marks.call(parallel: false)
    assert_equal [true, true, true, true], marks.call(parallel: true)
    assert_equal [true, false, false, true],
                 marks.call(parallel: { "wait" => false, "type" => true })
    assert_raises(Mistri::ConfigurationError) { marks.call(parallel: { wait: false }) }
    assert_raises(Mistri::ConfigurationError) { marks.call(parallel: { "wait_for" => false }) }
    assert_predicate Mistri::MCP.bridge(client, listed.first), :parallel?
    refute_predicate Mistri::MCP.bridge(client, listed.first, parallel: false), :parallel?
  end

  private

  def logging(name, ran, **)
    Mistri::Tool.define(name, "Logs.", **) do
      ran << name
      name
    end
  end

  def turn(*names)
    { tool_calls: names.map { |name| { name:, arguments: {} } } }
  end

  def answers_of(turn, tools, **)
    provider = Mistri::Providers::Fake.new(turns: [turn, { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools:, **)
    agent.run("go")
    agent.session.messages.select(&:tool?)
  end
end
