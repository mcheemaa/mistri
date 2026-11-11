# frozen_string_literal: true

require_relative "test_helper"

# What an agent counts as loaded: a tool that a successful result in the
# history has loaded. A search does not load it again, in a later turn or in
# the same one.
class TestDeferredToolsLoaded < Minitest::Test
  def tool(name, description = "Does #{name.tr("_", " ")}.")
    Mistri::Tool.define(name, description, deferred: true) { "ran #{name}" }
  end

  def search(query) = { name: "tool_search", arguments: { "query" => query } }

  def agent(turns, tools:, session: nil)
    [Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), session:, tools:)]
  end

  def test_two_searches_in_one_turn_do_not_load_the_same_tool
    many = Array.new(12) { |index| tool("tracker__issue_#{index}", "An issue tool.") }
    agent, = agent([{ tool_calls: [search("issue"), search("issue")] }, { text: "Ready." }],
                   tools: many)

    agent.run("Get ready.")
    loads = agent.session.messages.select(&:tool?).map(&:loads)

    assert_equal [4, 8], loads.map(&:length).sort
    assert_equal 12, loads.flatten.uniq.length
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
end
