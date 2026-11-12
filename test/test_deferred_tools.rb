# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# A deferred tool is not shown to the model until a tool result loads it. The
# load is stored with that result, so a later run offers the same tools.
class TestDeferredTools < Minitest::Test
  def tool(name, description = "Does #{name.tr("_", " ")}.", deferred: true, &handler)
    handler ||= -> { "ran #{name}" }
    Mistri::Tool.define(name, description, deferred:, &handler)
  end

  def tools
    [tool("lookup_order", deferred: false),
     tool("tracker__create_issue", "Opens an issue in the tracker."),
     tool("tracker__delete_issue", "Removes an issue from the tracker."),
     tool("docs__search_pages", "Finds pages in the handbook."),
     tool("refund_charge", "Gives a customer their money back.")]
  end

  def search(query, **more) = { name: "tool_search", arguments: { "query" => query, **more } }

  def agent(turns, session: nil, tools: self.tools, **)
    provider = Mistri::Providers::Fake.new(turns:)
    [Mistri::Agent.new(provider:, session:, tools:, **), provider]
  end

  def offered(provider, request = -1)
    provider.requests.fetch(request).dig(:options, :tools).map { |spec| spec[:name] }
  end

  def test_a_deferred_tool_is_offered_only_after_a_search_loads_it
    agent, provider = agent([{ tool_calls: [search("create issue")] },
                             { tool_calls: [{ name: "tracker__create_issue" }] },
                             { text: "Created." }])

    result = agent.run("Open an issue.")

    assert_predicate result, :completed?
    assert_equal %w[lookup_order tool_search], offered(provider, 0)
    assert_equal %w[lookup_order tool_search tracker__create_issue], offered(provider, 1)
    assert_equal ["ran tracker__create_issue"],
                 agent.session.messages.select { |m| m.tool_name == "tracker__create_issue" }
                      .map(&:text)
  end

  def test_the_search_answers_with_what_it_loaded_and_stores_the_names
    agent, = agent([{ tool_calls: [search("issue tracker")] }, { text: "Found." }])

    agent.run("Open an issue.")
    answer = agent.session.messages.find(&:tool?)

    assert_equal "tool_search", answer.tool_name
    assert_equal %w[tracker__create_issue tracker__delete_issue], answer.loads
    assert_equal "Loaded: tracker__create_issue, tracker__delete_issue. You can call them " \
                 "from your next step.", answer.text
    refute_predicate answer, :tool_error?
  end

  def test_a_later_run_with_a_fresh_agent_offers_what_was_loaded
    first, = agent([{ tool_calls: [search("handbook pages")] }, { text: "Found." }])
    first.run("Find the handbook.")

    second, provider = agent([{ text: "Here." }], session: first.session)
    second.run("And now?")

    assert_equal %w[lookup_order tool_search docs__search_pages], offered(provider, 0)
  end

  def test_the_names_survive_a_store_that_writes_json
    Dir.mktmpdir do |dir|
      session = Mistri::Session.new(store: Mistri::Stores::JSONL.new(dir))
      first, = agent([{ tool_calls: [search("refund")] }, { text: "Found." }], session:)
      first.run("Refund it.")

      reopened = Mistri::Session.new(id: session.id, store: Mistri::Stores::JSONL.new(dir))
      second, provider = agent([{ text: "Done." }], session: reopened)
      second.run("Go on.")

      assert_equal %w[lookup_order tool_search refund_charge], offered(provider, 0)
    end
  end

  def test_loaded_tools_follow_the_others_in_the_order_they_were_loaded
    agent, provider = agent([{ tool_calls: [search("refund")] },
                             { tool_calls: [search("handbook pages")] },
                             { tool_calls: [search("refund money")] },
                             { text: "Ready." }])

    agent.run("Get ready.")

    assert_equal %w[lookup_order tool_search refund_charge docs__search_pages], offered(provider)
  end

  def test_a_search_with_no_match_says_so_and_loads_nothing
    agent, provider = agent([{ tool_calls: [search("weather forecast")] }, { text: "None." }])

    agent.run("What is the weather?")
    answer = agent.session.messages.find(&:tool?)

    assert_equal "No tool matches. Try other words.", answer.text
    assert_nil answer.loads
    assert_equal %w[lookup_order tool_search], offered(provider)
  end

  def test_a_search_loads_at_most_the_limit_it_was_given
    many = Array.new(30) { |index| tool("tracker__issue_#{index}", "An issue tool.") }
    agent, provider = agent([{ tool_calls: [search("issue")] },
                             { tool_calls: [search("issue", limit: 500)] },
                             { tool_calls: [search("issue", limit: 1)] },
                             { text: "Ready." }], tools: many)

    agent.run("Get ready.")
    loads = agent.session.messages.select(&:tool?).map(&:loads)

    assert_equal [5, 20, 1], loads.map(&:length)
    assert_equal 26, loads.flatten.uniq.length
    assert_equal 27, offered(provider).length
  end

  def test_a_blank_query_is_an_error_the_model_can_read
    agent, = agent([{ tool_calls: [search("  ")] }, { text: "Sorry." }])

    agent.run("Search.")
    answer = agent.session.messages.find(&:tool?)

    assert_predicate answer, :tool_error?
    assert_match(/no words to search for/, answer.text)
    assert_nil answer.loads
  end

  def test_the_deferred_tools_are_listed_once_and_in_the_conversation
    agent, provider = agent([{ text: "Hello." }, { text: "Again." }])

    agent.run("Hello.")
    agent.run("Again.")
    listing = provider.requests.first[:messages].last.text
    search = provider.requests.first.dig(:options, :tools)
                     .find { |spec| spec[:name] == "tool_search" }

    assert_match(/\A<system-reminder>\n.*^tracker__create_issue$.*^refund_charge$/m, listing)
    refute_includes listing, "lookup_order"
    refute_includes search.fetch(:description), "tracker"
    assert_equal %w[deferred_tools], agent.session.messages.filter_map(&:reminder)
    assert_equal "Hello.", provider.requests.first[:messages].first.text
  end

  def test_an_agent_without_deferred_tools_is_as_before
    plain = [tool("lookup_order", deferred: false), tool("refund_charge", deferred: false)]
    agent, provider = agent([{ text: "Hello." }], tools: plain)

    agent.run("Hello.")

    assert_equal %w[lookup_order refund_charge], offered(provider)
  end

  def test_a_host_tool_named_tool_search_collides_loudly
    error = assert_raises(Mistri::ConfigurationError) do
      agent([], tools: [*tools, tool("tool_search", deferred: false)])
    end

    assert_match(/duplicate tool names/, error.message)
  end

  def test_a_deferred_tool_called_before_it_was_loaded_does_not_run
    ran = 0
    agent, = agent([{ tool_calls: [{ name: "refund_charge" }] },
                    { tool_calls: [search("select:refund_charge")] },
                    { tool_calls: [{ name: "refund_charge" }] }, { text: "Refunded." }],
                   tools: [tool("refund_charge") { ran += 1 }])

    result = agent.run("Refund it.")
    refused = agent.session.messages.find(&:tool?)

    assert_predicate result, :completed?
    assert_predicate refused, :tool_error?
    assert_match(/not loaded.*did not run.*tool_search.*select:refund_charge/m, refused.text)
    assert_equal 1, ran
  end

  def test_any_tool_can_load_deferred_tools_with_its_result
    opener = Mistri::Tool.define("open_tracker", "Opens the tracker.") do
      Mistri::ToolResult.new(content: "The tracker is open.",
                             loads: %w[tracker__create_issue lookup_order unknown_tool])
    end
    agent, provider = agent([{ tool_calls: [{ name: "open_tracker" }] }, { text: "Open." }],
                            tools: [opener, *tools])

    agent.run("Open the tracker.")

    assert_equal %w[open_tracker lookup_order tool_search tracker__create_issue], offered(provider)
  end

  def test_a_name_that_cannot_be_stored_is_an_error_the_model_reads_and_the_run_goes_on
    ran = 0
    names = [["\xFF".dup.force_encoding("UTF-8")], ["caf\xE9".b], ["x".encode("UTF-16LE")]]
    opener = Mistri::Tool.define("open_tracker", "Opens the tracker.") do
      ran += 1
      Mistri::ToolResult.new(content: "Open.", loads: names.shift)
    end
    turns = Array.new(3) { { tool_calls: [{ name: "open_tracker" }] } } + [{ text: "Done." }]
    agent, = agent(turns, tools: [opener, *tools])

    result = agent.run("Open the tracker three times.")
    answers = agent.session.messages.select(&:tool?)

    assert_predicate result, :completed?
    assert_equal 3, ran
    assert(answers.all?(&:tool_error?))
    assert(answers.all? { |answer| answer.text.include?("loads") })
    broken = ["\xFF".dup.force_encoding("UTF-8")]

    assert_raises(ArgumentError) do
      Mistri::Message.tool(content: "x", tool_call_id: "1", loads: broken)
    end
  end

  def test_a_query_is_read_up_to_five_hundred_characters
    target = tool("tracker__zebra", "Stripes.")
    padding = "q" * 494
    agent, = agent([{ tool_calls: [search("#{padding} zebra")] },
                    { tool_calls: [search("#{padding}  zebra")] }, { text: "Done." }],
                   tools: [target])

    agent.run("Find it.")
    loads = agent.session.messages.select(&:tool?).map(&:loads)

    assert_equal [%w[tracker__zebra], nil], loads
  end

  def test_a_query_with_nothing_to_search_by_says_so
    agent, = agent([{ tool_calls: [search("the of and")] }, { text: "Sorry." }])

    agent.run("Search.")
    answer = agent.session.messages.find(&:tool?)

    assert_predicate answer, :tool_error?
    assert_match(/no words to search for/, answer.text)
  end

  def test_a_failed_result_loads_nothing
    opener = Mistri::Tool.define("open_tracker", "Opens the tracker.") do
      Mistri::ToolResult.new(content: "The tracker is down.", error: true,
                             loads: %w[tracker__create_issue])
    end
    agent, provider = agent([{ tool_calls: [{ name: "open_tracker" }] }, { text: "Down." }],
                            tools: [opener, *tools])

    agent.run("Open the tracker.")
    answer = agent.session.messages.find(&:tool?)

    assert_predicate answer, :tool_error?
    assert_nil answer.loads
    assert_equal %w[open_tracker lookup_order tool_search], offered(provider)
  end

  def test_text_from_an_after_tool_hook_keeps_the_load
    shorten = ->(_call, result, _context) { result.content[0, 6] }
    agent, provider = agent([{ tool_calls: [search("refund")] }, { text: "Found." }],
                            after_tool: shorten)

    agent.run("Refund it.")
    answer = agent.session.messages.find(&:tool?)

    assert_equal "Loaded", answer.text
    assert_equal %w[refund_charge], answer.loads
    assert_equal %w[lookup_order tool_search refund_charge], offered(provider)
  end

  def test_a_load_the_model_no_longer_sees_is_no_longer_offered
    forget = ->(messages) { messages.reject(&:tool?).reject(&:tool_calls?) }
    first, = agent([{ tool_calls: [search("refund")] }, { text: "Found." }])
    first.run("Refund it.")

    second, provider = agent([{ text: "Gone." }], session: first.session, transform_context: forget)
    second.run("And now?")

    assert_equal %w[lookup_order tool_search], offered(provider)
  end

  def test_a_gate_on_a_loaded_tool_still_parks_the_call
    gated = Mistri::Tool.define("refund_charge", "Gives money back.",
                                deferred: true, needs_approval: true) { "refunded" }
    agent, = agent([{ tool_calls: [search("money back")] },
                    { tool_calls: [{ name: "refund_charge" }] }],
                   tools: [gated])

    result = agent.run("Refund it.")

    assert_equal :awaiting_approval, result.status
    assert_equal %w[refund_charge], result.pending.map(&:name)

    agent.session.approve(result.pending.first.id)
    later, = agent([{ text: "Refunded." }], session: agent.session, tools: [gated])

    assert_predicate later.resume, :completed?
    assert_equal "refunded", agent.session.messages.reverse_each.find(&:tool?).text
  end

  def test_a_specialist_with_deferred_tools_searches_for_them_itself
    child = Mistri::Providers::Fake.new(turns: [{ tool_calls: [search("refund")] },
                                                { tool_calls: [{ name: "refund_charge" }] },
                                                { text: "Refunded." }])
    billing = Mistri::SubAgent.new(name: "billing", description: "Handles money.",
                                   provider: child, tools:)
    agent, = agent([{ tool_calls: [{ name: "billing", arguments: { "task" => "Refund it." } }] },
                    { text: "Done." }], tools: [billing.tool])

    result = agent.run("Refund the customer.")

    assert_predicate result, :completed?
    assert_equal %w[lookup_order tool_search], offered(child, 0)
    assert_equal %w[lookup_order tool_search refund_charge], offered(child, 1)
  end

  def test_loads_is_a_list_of_names_on_a_tool_result_and_nowhere_else
    assert_raises(ArgumentError) { Mistri::ToolResult.new(content: "x", loads: "refund_charge") }
    assert_raises(ArgumentError) { Mistri::ToolResult.new(content: "x", loads: [:refund_charge]) }
    assert_raises(ArgumentError) do
      Mistri::Message.new(role: :user, content: "x", loads: ["refund_charge"])
    end
    assert_raises(ArgumentError) do
      Mistri::Message.from_h("role" => "tool", "tool_call_id" => "1", "loads" => 5)
    end
    assert_nil Mistri::Message.tool(content: "x", tool_call_id: "1", loads: []).loads
    refute Mistri::Message.tool(content: "x", tool_call_id: "1").to_h.key?(:loads)
  end

  def test_a_bridged_server_can_be_deferred_as_a_whole
    listed = [{ "name" => "create_issue", "description" => "Opens an issue." },
              { "name" => "list_teams", "description" => "Lists the teams." }]
    client = Struct.new(:tools).new(listed)

    deferred = Mistri::MCP.tools(client, prefix: "tracker", deferred: true)
    plain = Mistri::MCP.tools(client, prefix: "tracker")

    assert(deferred.all?(&:deferred?))
    assert(plain.none?(&:deferred?))
  end
end
