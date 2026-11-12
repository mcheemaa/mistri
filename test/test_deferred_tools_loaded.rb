# frozen_string_literal: true

require_relative "test_helper"

# What an agent counts as loaded: a tool that a successful result in the
# history names in its loads. A search does not load it again, in a later
# turn or in the same one: its result states that the tool is loaded and
# names it too.
class TestDeferredToolsLoaded < Minitest::Test
  def tool(name, description = "Does #{name.tr("_", " ")}.")
    Mistri::Tool.define(name, description, deferred: true) { "ran #{name}" }
  end

  def search(query) = { name: "tool_search", arguments: { "query" => query } }

  def agent(turns, tools:, session: nil)
    provider = Mistri::Providers::Fake.new(turns:)
    [Mistri::Agent.new(provider:, session:, tools:), provider]
  end

  # One exchange of four messages whose search result names these loads.
  def searched(session, id, loads, failed: false)
    call = Mistri::ToolCall.new(id:, name: "tool_search", arguments: {})
    [Mistri::Message.user("Go."),
     Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use),
     Mistri::Message.tool(content: "Loaded.", tool_call_id: id, tool_name: "tool_search", loads:,
                          tool_error: failed),
     Mistri::Message.assistant(content: "Done.", stop_reason: :stop)]
      .each { |message| session.append_message(message) }
  end

  def test_a_deferred_tool_that_is_not_a_tool_object_is_found_and_loaded
    duck = Class.new do
      def name = "duck_invoices"
      def spec = { name:, description: "Finds invoices.", input_schema: { type: "object" } }
      def deferred? = true
      def call(_arguments, _context) = "found"
      def needs_approval?(_arguments) = false
      def ends_turn? = false
      def timeout = nil
    end.new
    agent, = agent([{ tool_calls: [search("invoices")] },
                    { tool_calls: [{ name: "duck_invoices" }] }, { text: "Done." }], tools: [duck])

    agent.run("Find them.")

    assert_equal "found", agent.session.messages.select(&:tool?).last.text
  end

  def test_two_searches_in_one_turn_do_not_load_the_same_tool
    many = Array.new(8) { |index| tool("tracker__issue_#{index}", "An issue tool.") }
    agent, = agent([{ tool_calls: [search("issue"), search("issue")] }, { text: "Ready." }],
                   tools: many)

    agent.run("Get ready.")
    results = agent.session.messages.select(&:tool?)
    loaded = results.map { |result| result.text[/^Loaded: (.*?)\. /, 1].split(", ") }

    assert_equal [3, 5], loaded.map(&:length).sort
    assert_equal 8, loaded.flatten.uniq.length
    assert_equal [5, 8], results.map { |result| result.loads.length }.sort
  end

  def test_a_tool_stays_loaded_while_a_kept_result_states_that_it_is_loaded
    tools = [tool("refund_charge")]
    first, = agent([{ tool_calls: [search("select:refund_charge")] }, { text: "Loaded." }], tools:)
    first.run("Get ready.")
    session = first.session
    kept_from = session.entries.length
    again, = agent([{ tool_calls: [search("select:refund_charge")] }, { text: "Ready." }],
                   tools:, session:)
    again.run("Check it.")
    session.checkpoint(summary: "Ready.", kept_from:)
    later, provider = agent([{ text: "Done." }], tools:, session:)

    later.run("Refund it.")
    request = provider.requests.first

    assert_equal "Already loaded, call them directly: refund_charge.",
                 request[:messages].find(&:tool?).text
    assert_includes request[:options][:tools].map { |tool| tool[:name] }, "refund_charge"
    assert_empty session.last_compaction.dig("carried", "loaded")
  end

  def test_a_failed_result_that_names_loads_does_not_count_as_loaded
    call = Mistri::ToolCall.new(id: "call_1", name: "lookup_order", arguments: {})
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    [Mistri::Message.user("Go."),
     Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use),
     Mistri::Message.tool(content: "Down.", tool_call_id: "call_1", tool_name: "lookup_order",
                          tool_error: true, loads: %w[refund_charge])]
      .each { |message| session.append_message(message) }
    agent, = agent([{ tool_calls: [search("select:refund_charge")] }, { text: "Found." }],
                   session:, tools: [tool("refund_charge")])

    agent.run("Refund it.")

    assert_equal %w[refund_charge], session.messages.reverse_each.find(&:tool?).loads
  end

  def test_a_compaction_carries_the_names_of_the_tools_that_were_loaded
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    searched(session, "a", %w[tracker__create_issue tracker__list_issues])
    searched(session, "b", %w[docs__search_pages])

    session.checkpoint(summary: "First.", kept_from: 4)
    first = session.messages.first.text
    searched(session, "c", %w[tracker__create_issue])
    session.checkpoint(summary: "Second.", kept_from: 9)

    assert_match(/before this summary: tracker__create_issue, tracker__list_issues\. .*select:/,
                 first)
    assert_includes session.messages.first.text,
                    "before this summary: tracker__list_issues, docs__search_pages."
  end

  def test_a_failed_result_neither_adds_a_carried_name_nor_removes_one
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    searched(session, "a", %w[refund_charge])
    searched(session, "b", %w[void_charge], failed: true)
    searched(session, "c", %w[refund_charge], failed: true)

    session.checkpoint(summary: "First.", kept_from: 8)

    assert_equal %w[refund_charge], session.last_compaction.dig("carried", "loaded")
  end

  def test_a_tool_loaded_before_a_compaction_can_still_be_called
    tools = [tool("refund_charge"), tool("void_charge")]
    first, = agent([{ tool_calls: [search("select:refund_charge")] }, { text: "Loaded." }], tools:)
    first.run("Get ready.")
    first.session.checkpoint(summary: "Ready.", kept_from: first.session.entries.length)
    later, = agent([{ tool_calls: [{ name: "refund_charge" }, { name: "void_charge" }] },
                    { text: "Done." }], tools:, session: first.session)

    later.run("Refund it.")
    refunded, voided = first.session.messages.select(&:tool?).last(2)

    assert_equal "ran refund_charge", refunded.text
    assert_predicate voided, :tool_error?
    assert_match(/not loaded/, voided.text)
  end

  def test_an_invalid_call_to_a_tool_loaded_before_a_compaction_is_reported_as_not_loaded
    schema = -> { string :charge, required: true }
    refund = Mistri::Tool.define("refund_charge", "Refunds.", deferred: true, schema:) { "refunded" }
    first, = agent([{ tool_calls: [search("select:refund_charge")] }, { text: "Loaded." }],
                   tools: [refund])
    first.run("Get ready.")
    first.session.checkpoint(summary: "Ready.", kept_from: first.session.entries.length)
    later, = agent([{ tool_calls: [{ name: "refund_charge", arguments: { "charge" => 7 } }] },
                    { tool_calls: [{ name: "refund_charge", arguments: { "charge" => "ch_7" } }] },
                    { text: "Done." }], tools: [refund], session: first.session)

    later.run("Refund it.")
    invalid, valid = first.session.messages.select(&:tool?).last(2)

    assert_predicate invalid, :tool_error?
    assert_match(/not loaded, so it did not run\. Load it with tool_search first/, invalid.text)
    assert_equal "refunded", valid.text
  end
end
