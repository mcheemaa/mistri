# frozen_string_literal: true

require_relative "test_helper"

# The deferred tools are listed in the conversation: a reminder the agent
# appends once, and again when the list changed or a compaction removed it.
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

  def test_the_counted_list_is_bounded_and_counts_the_remaining_prefixes_together
    names = Array.new(2_000) { |index| "server_number_#{index}__read" }
    listing = Mistri::ToolSearch.listing(names)

    assert_operator listing.bytesize, :<, Mistri::ToolSearch::LISTING_BYTES + 500
    assert_match(/server_number_0 \(1 tool\), .*, \d{4} others\. Load one/, listing)
  end

  def test_a_compaction_does_not_summarize_the_list_and_it_is_appended_again
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

  def test_a_changed_list_is_appended_again
    one, = agent([{ text: "One." }])
    one.run("First.")
    two, = agent([{ text: "Two." }], session: one.session, tools: [tool("docs__search_pages")])
    two.run("Second.")
    again, provider = agent([{ text: "Three." }], session: one.session)

    again.run("Third.")
    listings = provider.requests.last[:messages].select(&:reminder).map(&:text)

    assert_equal 3, listings.length
    assert_includes listings.last, "tracker__create_issue"
    assert_includes listings[1], "docs__search_pages"
  end

  def test_an_agent_without_deferred_tools_withdraws_an_earlier_list_once
    one, = agent([{ text: "One." }])
    one.run("First.")
    plain, provider = agent([{ text: "Two." }, { text: "Three." }], session: one.session, tools: [])

    plain.run("Second.")
    plain.run("Third.")
    listings = provider.requests.last[:messages].select(&:reminder).map(&:text)

    assert_equal 2, listings.length
    assert_includes listings.last, "No tools load on demand now."
  end
end
