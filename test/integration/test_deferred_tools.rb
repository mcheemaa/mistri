# frozen_string_literal: true

require "delegate"
require_relative "../support/integration"

# Tools on demand against the real APIs: the model is shown one tool and a
# search, finds the tool it needs among the deferred ones, calls it, and a
# later run on the same session is offered it from its first request.
class TestDeferredToolsIntegration < Minitest::Test
  # Remembers the tool names of every request the agent makes.
  class Recorded < SimpleDelegator
    def offered = @offered ||= []

    def stream(**options, &)
      offered << options.fetch(:tools, []).map { |tool| tool[:name] }
      __getobj__.stream(**options, &)
    end
  end

  NAMES = %w[
    tracker__create_issue tracker__update_issue tracker__delete_issue tracker__list_issues
    tracker__get_issue tracker__create_project tracker__list_projects tracker__add_comment
    tracker__list_labels tracker__assign_issue billing__list_invoices billing__get_invoice
    billing__create_invoice billing__void_invoice billing__list_customers docs__search_pages
    docs__get_page docs__create_page
  ].freeze

  def deferred_tools(refunds)
    others = NAMES.map do |name|
      Mistri::Tool.define(name, "#{name.split("__").last.tr("_", " ").capitalize}.",
                          deferred: true) { "ran #{name}" }
    end
    refund = Mistri::Tool.define(
      "billing__refund_charge", "Gives a customer the money for one charge back.",
      deferred: true, schema: -> { string :charge, "The charge id", required: true }
    ) { "REFUND_ID=#{refunds.shift}" }
    [*others, refund]
  end

  def agent_for(model, session, tools)
    provider = Recorded.new(Mistri.provider(model))
    lookup = Mistri::Tool.define("lookup_order", "Finds an order by its number.") { "No order." }
    agent = Mistri::Agent.new(provider:, session:, tools: [lookup, *tools],
                              system: "You work on a shop's support desk. Be brief.")
    [agent, provider]
  end

  Integration.scenario(self, :a_deferred_tool_is_found_and_stays_loaded) do |model|
    first_refund = Integration.marker
    second_refund = Integration.marker
    tools = deferred_tools([first_refund, second_refund])
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    agent, provider = agent_for(model, session, tools)

    result = agent.run("Refund the charge ch_123, then tell me the refund id exactly as " \
                       "the tool returns it.")

    assert_predicate result, :completed?
    assert_equal %w[lookup_order tool_search], provider.offered.first
    loads = session.messages.select(&:tool?).flat_map { |message| message.loads.to_a }

    assert_includes loads, "billing__refund_charge", "the search never loaded the tool"
    assert Integration.carried?(result.text, first_refund),
           "the loaded tool's result never reached the answer: #{result.text}"

    later, provider = agent_for(model, session, tools)
    result = later.run("Now refund ch_456 as well and give me its refund id.")

    assert_predicate result, :completed?
    assert_includes provider.offered.first, "billing__refund_charge",
                    "a later run was not offered the loaded tool"
    assert Integration.carried?(result.text, second_refund),
           "the later run never used the loaded tool: #{result.text}"
  end

  Integration.scenario(self, :a_deferred_mcp_server_is_searched_and_used) do |model|
    client = Mistri::MCP::Client.new(url: "https://mcp.deepwiki.com/mcp")
    begin
      begin
        client.connect
      rescue Mistri::ProviderError => e
        raise unless Integration.mcp_unreachable?(e) && !Integration.strict?

        skip "DeepWiki MCP unreachable: #{e.message}"
      end

      called = []
      bridged = Mistri::MCP.tools(client, prefix: "deepwiki", deferred: true)
      provider = Recorded.new(Mistri.provider(model))
      agent = Mistri::Agent.new(provider:, tools: bridged,
                                system: "Answer from the deepwiki tools. Be brief.")

      result = agent.run("What documentation topics exist for the " \
                         "modelcontextprotocol/ruby-sdk repo? Name two.") do |event|
        called << event.tool_call.name if event.type == :tool_result && !event.tool_error
      end

      assert_predicate result, :completed?
      assert_equal %w[tool_search], provider.offered.first
      assert_includes called, "tool_search"
      assert(called.any? { |name| name.start_with?("deepwiki__") },
             "the agent never used a tool of the deferred server")
      assert_operator result.text.to_s.length, :>, 20
    ensure
      client.close
    end
  end
end
