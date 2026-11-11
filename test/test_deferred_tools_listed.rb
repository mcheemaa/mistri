# frozen_string_literal: true

require_relative "test_helper"

# The model reads what can be loaded in the conversation: a reminder the
# harness stores once, and again when the list changed or a compaction took
# it away.
class TestDeferredToolsListed < Minitest::Test
  def tool(name, **)
    Mistri::Tool.define(name, "Does #{name.tr("_", " ")}.", deferred: true, **) { "ran #{name}" }
  end

  def agent(turns, tools: [tool("tracker__create_issue")], **)
    provider = Mistri::Providers::Fake.new(turns:)
    [Mistri::Agent.new(provider:, tools:, **), provider]
  end

  def reminders(session) = session.messages.map(&:reminder)

  def test_too_many_tools_to_name_are_counted_under_each_prefix
    many = Array.new(900) { |index| "tracker__operation_number_#{index}" }

    listing = Mistri::ToolSearch.listing(many + ["refund_charge"])

    assert_includes listing, "tracker (900 tools), 1 other"
    refute_includes listing, "tracker__operation_number_1"
  end

  def test_a_compaction_never_summarizes_the_list_and_it_is_said_again
    agent, provider = agent([{ text: "One." }, { text: "Two." }, { text: "Summary." },
                             { text: "Three." }],
                            compaction: Mistri::Compaction.new(keep_recent: 1))

    agent.run("First.")
    agent.run("Second.")
    agent.compact
    agent.run("Third.")

    refute_includes provider.requests[2][:messages].last.text, "load on demand"
    assert_equal [nil, nil, nil, nil, "deferred_tools", nil], reminders(agent.session)
  end

  def test_a_list_that_changed_is_said_again
    one, = agent([{ text: "One." }])
    one.run("First.")
    two, = agent([{ text: "Two." }], session: one.session, tools: [tool("docs__search_pages")])
    two.run("Second.")
    again, provider = agent([{ text: "Three." }], session: one.session)

    again.run("Third.")
    told = provider.requests.last[:messages].select(&:reminder).map(&:text)

    assert_equal 3, told.length
    assert_includes told.last, "tracker__create_issue"
    assert_includes told[1], "docs__search_pages"
  end
end
