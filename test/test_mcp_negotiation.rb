# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"

# Which revision a client speaks with a server over HTTP: it asks once, takes
# the 2026-07-28 form when the server has it, and otherwise does the handshake.
class TestMcpNegotiation < Minitest::Test
  NEWEST = { "resultType" => "complete", "supportedVersions" => ["2026-07-28"],
             "capabilities" => { "tools" => {} }, "instructions" => "Use with care.",
             "_meta" => { "io.modelcontextprotocol/serverInfo" => { "name" => "scripted" } } }
           .freeze
  ECHO = ->(server, socket, id) { server.result(socket, id, server.answer(id, "echo")["result"]) }
  REFUSED = lambda do |server, socket, id|
    server.refuse(socket, id, code: -32_000, message: "Mcp-Session-Id header is required",
                              status: 400)
  end
  UNSUPPORTED = lambda do |supported|
    lambda do |server, socket, id|
      server.refuse(socket, id, code: -32_022, message: "Unsupported protocol version",
                                data: { "supported" => supported }, status: 400)
    end
  end

  def teardown
    @client&.close
    @server&.stop
  end

  def test_a_server_that_has_the_newest_revision_gets_no_handshake_and_no_session
    client(discover: NEWEST).call_tool("echo", {})
    @client.close

    assert_equal %w[server/discover tools/list tools/call], methods
    assert_equal "Use with care.", @client.instructions
    assert_equal "2026-07-28", @client.listing["protocolVersion"]
    assert_empty @server.requests("DELETE")
    assert_nil @server.requests("POST").last[:headers]["mcp-session-id"]
  end

  def test_every_request_of_the_newest_revision_says_what_it_is
    client(discover: NEWEST).call_tool("echo", {})
    described = { "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                  "io.modelcontextprotocol/clientInfo" => { "name" => "mistri",
                                                            "version" => Mistri::VERSION },
                  "io.modelcontextprotocol/clientCapabilities" => {} }
    headers = @server.requests("POST").map { |request| request[:headers] }

    assert_equal([described] * 3, @server.posted.map { |message| message.dig("params", "_meta") })
    assert_equal(["2026-07-28"] * 3, headers.map { |sent| sent["mcp-protocol-version"] })
    assert_equal(%w[server/discover tools/list tools/call], headers.map do |sent|
      sent["mcp-method"]
    end)
    assert_equal([nil, nil, "echo"], headers.map { |sent| sent["mcp-name"] })
    assert_equal "scripted", @client.server_info["name"]
  end

  def test_an_older_server_gets_the_handshake_however_it_answers
    [nil, REFUSED, { "tools" => [] }, UNSUPPORTED.call(["2025-11-25"]),
     NEWEST.merge("supportedVersions" => ["2025-06-18"])].each do |answer|
      client(discover: answer).call_tool("echo", {})

      assert_equal %w[server/discover initialize notifications/initialized tools/call], methods
      assert_equal "2025-11-25", @client.listing["protocolVersion"]
      assert_nil @server.posted.last.dig("params", "_meta")
      teardown
    end
  end

  def test_a_refused_version_is_asked_again_with_one_the_server_names
    asked = 0
    once = lambda do |server, socket, id|
      next UNSUPPORTED.call(["2026-07-28"]).call(server, socket, id) if (asked += 1) == 1

      server.result(socket, id, NEWEST)
    end
    client(discover: once).call_tool("echo", {})

    assert_equal %w[server/discover server/discover tools/list tools/call], methods
  end

  def test_a_server_with_no_revision_in_common_is_refused_in_words
    [UNSUPPORTED.call(["2099-01-01"]), NEWEST.merge("supportedVersions" => ["2099-01-01"]),
     UNSUPPORTED.call(["2026-07-28"])].each do |answer|
      error = assert_raises(Mistri::Error) { client(discover: answer).connect }

      assert_match(/no protocol version this client does: 2099-01-01|HTTP 400/, error.message)
      assert_empty @server.sent("initialize")
      teardown
    end
  end

  def test_a_refusal_that_says_nothing_of_the_revision_is_raised_as_it_is
    { 401 => Mistri::AuthenticationError, 503 => Mistri::ServerError }.each do |status, error|
      answer = ->(server, socket, _id) { server.json(socket, "no", status: status) }

      assert_raises(error) { client(discover: answer).connect }
      assert_empty @server.sent("initialize")
      teardown
    end
  end

  def test_a_client_built_from_a_listing_asks_nothing
    kept = client(discover: NEWEST).listing
    @client.close
    again = Mistri::MCP::Client.new(url: @server.url, listing: kept,
                                    allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
    before = @server.posted.length
    again.call_tool("echo", {})

    assert_equal ["tools/call"], methods.drop(before)
    assert_equal "2026-07-28", @server.requests("POST").last[:headers]["mcp-protocol-version"]
  ensure
    again&.close
  end

  def test_a_client_built_from_an_older_listing_goes_straight_to_the_handshake
    kept = client.listing
    @client.close
    again = Mistri::MCP::Client.new(url: @server.url, listing: kept,
                                    allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
    before = @server.posted.length
    again.call_tool("echo", {})

    assert_equal %w[initialize notifications/initialized tools/call], methods.drop(before)
  ensure
    again&.close
  end

  def test_a_server_that_stopped_taking_the_remembered_form_is_asked_again
    kept = { "tools" => [], "protocolVersion" => "2026-07-28" }
    refused = 0
    tools = { "echo" => lambda do |server, socket, id|
      next REFUSED.call(server, socket, id) if (refused += 1) == 1

      ECHO.call(server, socket, id)
    end }
    @server = Mistri::Test::McpScriptedServer.new(tools: tools)
    @client = Mistri::MCP::Client.new(url: @server.url, listing: kept,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK)

    result = @client.call_tool("echo", {})

    assert_equal "echo", result.dig("content", 0, "text")
    assert_equal %w[tools/call server/discover initialize notifications/initialized tools/call],
                 methods
  end

  def test_an_error_of_a_call_is_not_taken_for_a_refused_form
    failing = { "echo" => lambda do |server, socket, id|
      server.refuse(socket, id, code: -32_602, message: "Unknown tool")
    end }
    @server = Mistri::Test::McpScriptedServer.new(tools: failing, discover: NEWEST)
    @client = Mistri::MCP::Client.new(url: @server.url,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK)

    error = assert_raises(Mistri::MCP::Error) { @client.call_tool("echo", {}) }
    @client.call_tool("echo", {}) rescue nil # rubocop:disable Style/RescueModifier

    assert_equal [-32_602, nil], [error.code, error.data]
    assert_equal %w[server/discover tools/list tools/call tools/call], methods
    assert_equal 1, @server.accepts, "an error that was read whole keeps its connection"
  end

  private

  def client(**)
    @server = Mistri::Test::McpScriptedServer.new(tools: { "echo" => ECHO }, **)
    @client = Mistri::MCP::Client.new(url: @server.url,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
  end

  def methods = @server.posted.map { |message| message["method"] }
end
