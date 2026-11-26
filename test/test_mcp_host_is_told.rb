# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"

# What a host learns from a client: the notices a server sends, progress when
# it asked for it, and whether the server answered, is down or needs a sign-in.
class TestMcpHostIsTold < Minitest::Test
  NEWEST = { "supportedVersions" => ["2026-07-28"] }.freeze
  CHANGED = { "jsonrpc" => "2.0", "method" => "notifications/tools/list_changed" }.freeze
  TOOLS = {
    "echo" => lambda { |server, socket, id|
      server.result(socket, id, server.answer(id, "echo")["result"])
    },
    "changes" => lambda do |server, socket, id|
      server.open(socket)
      server.event(socket, CHANGED)
      server.event(socket, server.answer(id, "changed"))
      server.finish(socket)
    end,
    "works" => lambda do |server, socket, id|
      token = server.sent("tools/call").last.dig("params", "_meta", "progressToken")
      server.open(socket)
      5.times do |step|
        sleep 0.1
        server.event(socket, { "jsonrpc" => "2.0", "method" => "notifications/progress",
                               "params" => { "progressToken" => token, "progress" => step + 1 } })
      end
      server.event(socket, server.answer(id, "worked"))
      server.finish(socket)
    end,
    "fails" => ->(server, socket, id) { server.refuse(socket, id, code: -32_602, message: "No.") },
    "large" => lambda { |server, socket, id|
      server.result(socket, id, server.answer(id, "x" * 20_000)["result"])
    },
    "broken" => ->(server, socket, _id) { server.json(socket, "no", status: 503) },
    "locked" => ->(server, socket, _id) { server.json(socket, "no", status: 401) },
    "silent" => lambda do |server, socket, _id|
      server.open(socket)
      sleep 1
      :close
    end
  }.freeze

  def teardown
    @client&.close
    @server&.stop
  end

  def test_a_notice_reaches_the_host_and_the_kept_list_stays_as_it_was
    told = []
    client(on_notification: ->(method, params) { told << [method, params] })
    before = @client.tools

    @client.call_tool("changes", {})

    assert_equal [["notifications/tools/list_changed", nil]], told
    assert_same before, @client.tools
    assert_equal 1, @server.sent("tools/list").length
  end

  def test_what_the_hosts_callable_raises_is_reported_and_the_call_goes_on
    client(on_notification: ->(_method, _params) { raise ArgumentError, "the host's own fault" })
    result = nil

    _out, err = capture_io { result = @client.call_tool("changes", {}) }

    assert_equal "changed", result.dig("content", 0, "text")
    assert_equal "mistri: on_notification failed (ArgumentError: the host's own fault)\n", err
    assert_equal :connected, @client.state
  end

  def test_progress_reaches_the_host_that_asked_and_keeps_the_call_waiting
    told = []
    client(progress: true, read_timeout: 0.3, on_notification: lambda { |_method, params|
      told << params
    })

    result = @client.call_tool("works", {})
    call = @server.sent("tools/call").last

    assert_equal "worked", result.dig("content", 0, "text")
    assert_equal call["id"], call.dig("params", "_meta", "progressToken")
    assert_equal([1, 2, 3, 4, 5], told.map { |params| params["progress"] })
    assert_equal [call["id"]], told.map { |params| params["progressToken"] }.uniq
  end

  def test_progress_is_asked_for_in_the_newer_form_and_only_with_a_call
    client(progress: true, server: { discover: NEWEST }).call_tool("echo", {})

    assert_equal %w[io.modelcontextprotocol/protocolVersion io.modelcontextprotocol/clientInfo
                    io.modelcontextprotocol/clientCapabilities progressToken],
                 @server.sent("tools/call").last.dig("params", "_meta").keys
    refute @server.sent("tools/list").last.dig("params", "_meta").key?("progressToken")
  end

  def test_a_call_with_no_meta_carries_none
    client.call_tool("echo", {})

    refute @server.sent("tools/call").last["params"].key?("_meta")
  end

  def test_the_state_says_whether_the_server_answered
    client

    assert_equal [:idle, nil], [@client.state, @client.failure]

    @client.tools

    assert_equal :connected, @client.state

    assert_raises(Mistri::MCP::Error) { @client.call_tool("fails", {}) }

    assert_equal :connected, @client.state, "a server that answers with an error is there"

    @client.close

    assert_equal :idle, @client.state
  end

  def test_a_call_that_timed_out_or_answered_too_much_leaves_the_state_as_it_was
    client(read_timeout: 0.3, max_record_bytes: 8_000).tools

    assert_raises(Mistri::AmbiguousDeliveryError) { @client.call_tool("silent", {}) }
    assert_equal [:connected, nil], [@client.state, @client.failure]

    error = assert_raises(Mistri::AmbiguousDeliveryError) { @client.call_tool("large", {}) }

    assert_kind_of Mistri::ResponseTooLargeError, error.cause
    assert_equal [:connected, nil], [@client.state, @client.failure]
  end

  def test_an_error_of_the_hosts_own_leaves_the_state_as_it_was
    client(token: -> { raise IndexError, "no token is stored" })

    assert_raises(IndexError) { @client.tools }
    assert_equal [:idle, nil], [@client.state, @client.failure]
  end

  def test_a_server_that_needs_a_sign_in_is_told_from_one_that_is_down
    refusing = ->(server, socket, _id) { server.json(socket, "no", status: 401) }
    client(server: { discover: refusing })

    assert_raises(Mistri::AuthenticationError) { @client.tools }
    assert_equal [:needs_sign_in, "the MCP server did not authorize the request"],
                 [@client.state, @client.failure]

    teardown
    client
    @server.stop
    error = assert_raises(Mistri::ProviderError) { @client.tools }

    refute_kind_of Mistri::MCP::NotSent, error
    assert_equal :failed, @client.state
    assert_match(/connection failed/, @client.failure)
  end

  def test_a_server_that_answers_again_is_connected_again
    client.tools

    assert_raises(Mistri::ProviderError) { @client.call_tool("broken", {}) }
    assert_equal [:failed, "the MCP server answered HTTP 503"], [@client.state, @client.failure]

    @client.call_tool("echo", {})

    assert_equal [:connected, nil], [@client.state, @client.failure]
  end

  def test_a_local_server_that_cannot_start_has_failed
    @client = Mistri::MCP::Client.new(command: ["/nonexistent/mcp-server"])

    assert_raises(Errno::ENOENT) { @client.tools }
    assert_equal :failed, @client.state
    assert_match(/No such file or directory/, @client.failure)
  end

  def test_a_tool_whose_server_is_down_names_the_server_and_says_why
    listing = { "tools" => [{ "name" => "locked" }, { "name" => "echo" }] }
    locked, echo = Mistri::MCP.tools(client(listing: listing), prefix: "tracker")
    refused = locked.call({})
    @server.stop
    down = echo.call({})

    assert_equal [true, true], [refused.error, down.error]
    assert_equal 'tracker__locked did not run: the MCP server "tracker" needs a sign-in before ' \
                 "its tools can be used (the MCP server did not authorize the request).",
                 refused.content
    assert_match(/\ANo connection to the MCP server "tracker" could be established, so /,
                 down.content)
    assert_match(/tracker__echo did not run: connection failed: /, down.content)
    assert_equal :failed, @client.state
  end

  def test_a_tool_bridged_with_no_prefix_names_no_server
    listing = { "tools" => [{ "name" => "echo" }] }
    echo = Mistri::MCP.tools(client(listing: listing)).first
    @server.stop

    assert_match(/\ANo connection to the MCP server could be established, so echo did not run: /,
                 echo.call({}).content)
  end

  private

  def client(server: {}, **)
    @server = Mistri::Test::McpScriptedServer.new(tools: TOOLS, **server)
    @client = Mistri::MCP::Client.new(url: @server.url, read_timeout: 10,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **)
  end
end
