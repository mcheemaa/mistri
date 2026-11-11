# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "support/stub_server"

# On Anthropic every deferred definition travels with defer_loading, which
# keeps it out of the prompt, and a result that loads tools carries
# references to them. The tool list never changes, so the cache holds.
class TestAnthropicDeferredTools < Minitest::Test
  SERIALIZER = Mistri::Providers::Anthropic::Serializer
  CALL = Mistri::ToolCall.new(id: "call_1", name: "tool_search", arguments: { "query" => "issue" })

  def spec(name) = { name:, description: "Does #{name}.", input_schema: { "type" => "object" } }

  def loading(loads, content: "Loaded.", id: "call_1", **)
    Mistri::Message.tool(content:, tool_call_id: id, tool_name: "tool_search", loads:, **)
  end

  def history(*results)
    [Mistri::Message.user("go"),
     Mistri::Message.assistant(tool_calls: [CALL], stop_reason: :tool_use), *results]
  end

  def teardown
    @provider&.close
    @server&.stop
  end

  def test_a_deferred_definition_is_marked_and_follows_the_others
    wire = SERIALIZER.tools([spec("lookup")], [spec("create_issue"), spec("list_teams")])

    assert_equal(%w[lookup create_issue list_teams], wire.map { |tool| tool[:name] })
    assert_equal([nil, true, true], wire.map { |tool| tool[:defer_loading] })
    assert_equal({ "type" => "object" }, wire.last[:input_schema])
  end

  def test_a_result_that_loads_tools_carries_references_and_its_text_follows
    wire = SERIALIZER.messages(history(loading(%w[create_issue list_teams])),
                               deferred: %w[create_issue list_teams delete_issue])

    result, text = wire.last[:content]

    assert_equal "tool_result", result[:type]
    assert_equal [{ type: "tool_reference", tool_name: "create_issue" },
                  { type: "tool_reference", tool_name: "list_teams" }], result[:content]
    assert_equal({ type: "text", text: "Loaded." }, text)
    assert_equal 2, wire.last[:content].length
  end

  def test_a_name_that_is_no_longer_a_deferred_tool_is_not_referenced
    gone = SERIALIZER.messages(history(loading(%w[create_issue retired])),
                               deferred: %w[create_issue])
    none = SERIALIZER.messages(history(loading(%w[retired])), deferred: %w[create_issue])

    assert_equal [{ type: "tool_reference", tool_name: "create_issue" }],
                 gone.last[:content].first[:content]
    assert_equal [{ type: "tool_result", tool_use_id: "call_1",
                    content: [{ type: "text", text: "Loaded." }] }], none.last[:content]
  end

  def test_a_request_without_deferred_tools_sends_the_text_alone
    wire = SERIALIZER.messages(history(loading(%w[create_issue])))

    assert_equal [{ type: "tool_result", tool_use_id: "call_1",
                    content: [{ type: "text", text: "Loaded." }] }], wire.last[:content]
  end

  def test_a_failed_result_carries_no_reference
    wire = SERIALIZER.messages(history(loading(%w[create_issue], tool_error: true)),
                               deferred: %w[create_issue])

    assert_equal [{ type: "tool_result", tool_use_id: "call_1", is_error: true,
                    content: [{ type: "text", text: "Loaded." }] }], wire.last[:content]
  end

  def test_text_comes_after_every_result_of_the_turn
    plain = Mistri::Message.tool(content: "Order 7.", tool_call_id: "call_2", tool_name: "lookup")
    wire = SERIALIZER.messages(history(loading(%w[create_issue]), plain,
                                       loading(%w[list_teams], content: "", id: "call_3")),
                               deferred: %w[create_issue list_teams])

    assert_equal(%w[tool_result tool_result tool_result text],
                 wire.last[:content].map { |block| block[:type] })
    assert_equal [{ type: "text", text: "Order 7." }], wire.last[:content][1][:content]
    assert_equal "Loaded.", wire.last[:content].last[:text]
  end

  def test_the_cache_mark_lands_on_the_last_block_of_the_turn
    wire = SERIALIZER.messages(history(loading(%w[create_issue])), cache: true,
                                                                   deferred: %w[create_issue])

    assert_equal({ type: "ephemeral" }, wire.last[:content].last[:cache_control])
    refute wire.last[:content].first.key?(:cache_control)
  end

  def test_the_official_origin_holds_definitions_back_and_another_origin_does_not
    official = Mistri::Providers::Anthropic.new(api_key: "k")
    other = Mistri::Providers::Anthropic.new(api_key: "k", origin: "https://gateway.example")

    assert_predicate official, :defers_tools?
    refute_predicate other, :defers_tools?
  ensure
    official&.close
    other&.close
  end

  def test_the_request_carries_every_deferred_definition_and_the_references
    @server = Mistri::Test::StubServer.new do |socket, _request|
      @server.start_sse(socket)
      @server.sse_data(socket, { "type" => "message_stop" })
      @server.finish_sse(socket)
    end
    @provider = Mistri::Providers::Anthropic.new(api_key: "k", origin: @server.origin)

    @provider.stream(messages: history(loading(%w[create_issue])), tools: [spec("tool_search")],
                     deferred_tools: [spec("create_issue"), spec("list_teams")])
    body = JSON.parse(@server.requests.first[:body])

    assert_equal([nil, true, true], body["tools"].map { |tool| tool["defer_loading"] })
    assert_equal [{ "type" => "tool_reference", "tool_name" => "create_issue" }],
                 body["messages"].last["content"].first["content"]
  end

  def test_deferred_definitions_travel_when_they_are_the_only_tools
    @server = Mistri::Test::StubServer.new do |socket, _request|
      @server.start_sse(socket)
      @server.sse_data(socket, { "type" => "message_stop" })
      @server.finish_sse(socket)
    end
    @provider = Mistri::Providers::Anthropic.new(api_key: "k", origin: @server.origin)
    deferred = [spec("create_issue")]

    @provider.stream(messages: [Mistri::Message.user("go")], deferred_tools: deferred)
    @provider.stream(messages: history(loading(%w[create_issue])), deferred_tools: deferred)
    first, replay = @server.requests.map { |request| JSON.parse(request[:body]) }

    [first, replay].each do |body|
      assert_equal([["create_issue", true]],
                   body["tools"].map { |tool| [tool["name"], tool["defer_loading"]] })
    end
    assert_equal [{ "type" => "tool_reference", "tool_name" => "create_issue" }],
                 replay["messages"].last["content"].first["content"]
  end

  def test_a_tool_is_referenced_by_the_name_its_definition_is_sent_with
    @server = Mistri::Test::StubServer.new do |socket, _request|
      @server.start_sse(socket)
      @server.sse_data(socket, { "type" => "message_stop" })
      @server.finish_sse(socket)
    end
    @provider = Mistri::Providers::Anthropic.new(api_key: "k", origin: @server.origin)
    renamed = [spec("lookup").merge("name" => "crm__lookup")]

    @provider.stream(messages: history(loading(%w[crm__lookup])), deferred_tools: renamed)
    @provider.stream(messages: history(loading(%w[lookup])), deferred_tools: renamed)
    sent, other = @server.requests.map { |request| JSON.parse(request[:body]) }

    assert_equal(%w[crm__lookup], sent["tools"].map { |tool| tool["name"] })
    assert_equal [{ "type" => "tool_reference", "tool_name" => "crm__lookup" }],
                 sent["messages"].last["content"].first["content"]
    refute_includes JSON.generate(other["messages"]), "tool_reference"
  end

  def test_an_agent_gives_such_a_provider_the_same_tools_every_turn
    provider = Class.new(Mistri::Providers::Fake) { def defers_tools? = true }.new(
      turns: [{ tool_calls: [{ name: "tool_search", arguments: { "query" => "issue" } }] },
              { tool_calls: [{ name: "create_issue" }] }, { text: "Created." }]
    )
    lookup = Mistri::Tool.define("lookup", "Finds an order.") { "none" }
    create = Mistri::Tool.define("create_issue", "Opens an issue.", deferred: true) { "created" }
    teams = Mistri::Tool.define("list_teams", "Lists teams.", deferred: true) { "none" }

    Mistri::Agent.new(provider:, tools: [lookup, create, teams]).run("Open an issue.")
    requests = provider.requests.map { |request| request[:options] }

    assert_equal 3, requests.length
    requests.each do |options|
      assert_equal(%w[lookup tool_search], options[:tools].map { |tool| tool[:name] })
      assert_equal(%w[create_issue list_teams], options[:deferred_tools].map { |tool| tool[:name] })
    end
  end

  def test_an_agent_without_deferred_tools_passes_no_such_option
    provider = Class.new(Mistri::Providers::Fake) { def defers_tools? = true }.new(
      turns: [{ text: "Hello." }]
    )
    lookup = Mistri::Tool.define("lookup", "Finds an order.") { "none" }

    Mistri::Agent.new(provider:, tools: [lookup]).run("Hello.")

    refute provider.requests.first[:options].key?(:deferred_tools)
  end
end
