# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"

# What the client does with a token the server refuses: it asks the host's
# callable again, hands it the refused token when the callable takes it, and
# does not ask again when the server wants more scope.
class TestMcpRefusedToken < Minitest::Test
  STEP_UP = 'Bearer error="insufficient_scope", scope="files:write", ' \
            'resource_metadata="https://mcp.example/.well-known/oauth-protected-resource"'
  GUARDED = lambda do |server, socket, id|
    if server.requests("POST").last[:headers]["authorization"] == "Bearer new"
      server.result(socket, id, server.answer(id, "let in")["result"])
    else
      server.json(socket, "no", status: 401,
                                headers: { "WWW-Authenticate" => 'Bearer error="invalid_token"' })
    end
  end
  TOOLS = {
    "guarded" => GUARDED,
    "needs_more" => lambda do |server, socket, _id|
      server.json(socket, "no", status: 403, headers: { "WWW-Authenticate" => STEP_UP })
    end,
    "forbidden" => ->(server, socket, _id) { server.json(socket, "no", status: 403) }
  }.freeze

  # A token source that is an object, not a proc.
  class Vault
    attr_reader :refused

    def call(refused: nil)
      @refused = refused if refused
      @refused ? "new" : "old"
    end
  end

  def teardown
    @client&.close
    @server&.stop
  end

  def test_a_callable_that_takes_the_refused_token_is_given_it
    asked = []
    current = "old"
    client(lambda do |refused: nil|
      asked << refused
      current = "new" if refused == current
      current
    end)

    assert_equal "let in", @client.call_tool("guarded", {}).dig("content", 0, "text")
    assert_equal ["old"], asked.compact
    assert_equal "new", asked.empty? ? nil : current
    assert_equal :connected, @client.state
  end

  def test_an_object_and_a_callable_with_any_keyword_are_given_it_too
    vault = Vault.new
    client(vault)
    @client.call_tool("guarded", {})

    assert_equal "old", vault.refused

    teardown
    seen = []
    client(lambda do |**given|
      seen << given
      given.empty? && seen.none? { |earlier| earlier.key?(:refused) } ? "old" : "new"
    end)
    @client.call_tool("guarded", {})

    assert_includes seen, { refused: "old" }
  end

  def test_a_callable_that_takes_nothing_is_asked_again_as_before
    refused = false
    tools = TOOLS.merge("guarded" => lambda do |server, socket, id|
      refused = true unless server.requests("POST").last[:headers]["authorization"] == "Bearer new"
      GUARDED.call(server, socket, id)
    end)
    client(-> { refused ? "new" : "old" }, tools: tools)

    assert_equal "let in", @client.call_tool("guarded", {}).dig("content", 0, "text")
    assert_equal 2, @server.sent("tools/call").length
  end

  def test_a_403_that_asks_for_more_scope_is_not_asked_about_again
    asked = 0
    client(lambda do
      asked += 1
      "old"
    end)
    @client.tools
    before = asked
    error = assert_raises(Mistri::AuthenticationError) { @client.call_tool("needs_more", {}) }

    assert_equal 1, asked - before
    assert_equal 1, @server.sent("tools/call").length
    assert_equal [403, STEP_UP], [error.status, error.challenge]
    assert_equal ["insufficient_scope", "files:write"],
                 Mistri::MCP::OAuth.challenge(error).values_at("error", "scope")
    assert_equal :needs_sign_in, @client.state
  end

  def test_a_403_with_no_such_challenge_is_asked_about_once_more_as_before
    client(-> { "old" })
    error = assert_raises(Mistri::AuthenticationError) { @client.call_tool("forbidden", {}) }

    assert_equal 2, @server.sent("tools/call").length
    assert_equal [403, nil], [error.status, error.challenge]
  end

  def test_a_bridged_tool_that_needs_more_scope_says_the_server_needs_a_sign_in
    listing = { "tools" => [{ "name" => "needs_more" }] }
    client(-> { "old" }, listing: listing)
    result = Mistri::MCP.tools(@client, prefix: "files").first.call({})

    assert result.error
    assert_match(/\Afiles__needs_more did not run: the MCP server "files" needs a sign-in/,
                 result.content)
  end

  def test_a_grant_that_is_spent_when_a_call_is_about_to_go_out_needs_a_sign_in
    gone = Mistri::MCP::OAuth::InvalidGrantError.new("token request failed (400): invalid_grant",
                                                     status: 400, reason: "invalid_grant")
    spent = false
    client(-> { spent ? raise(gone) : "new" }).connect
    tool = Mistri::MCP.bridge(@client, { "name" => "guarded" }, prefix: "files")
    spent = true
    result = tool.call({})

    assert result.error
    assert_equal 'files__guarded did not run: the MCP server "files" needs a sign-in before ' \
                 "its tools can be used (token request failed (400): invalid_grant).",
                 result.content
    assert_empty @server.sent("tools/call")
    assert_equal [:needs_sign_in, gone.message], [@client.state, @client.failure]
    refute_kind_of Mistri::MCP::NotSent, gone
  end

  private

  def client(token, tools: TOOLS, **)
    @server = Mistri::Test::McpScriptedServer.new(tools: tools)
    @client = Mistri::MCP::Client.new(url: @server.url, token: token, read_timeout: 10,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **)
  end
end
