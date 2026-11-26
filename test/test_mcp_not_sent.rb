# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_stub_server"

# An error that Client#call_tool raises before the call is sent is raised as a
# copy tagged NotSent. The error a caller owns is never changed.
class TestMcpNotSent < Minitest::Test
  ECHO = { "echo" => { description: "Echoes.", handler: ->(_args) { "echo" } } }.freeze
  # A module a host tags its own errors with.
  HostTag = Module.new
  # Raises the error a test set, once, from the next read of a connection.
  FailingRead = Module.new do
    def rbuf_fill
      error = Thread.current[:mistri_test_read_error]
      return super unless error

      Thread.current[:mistri_test_read_error] = nil
      raise error
    end
  end
  Net::BufferedIO.prepend(FailingRead)

  def with_server
    server = Mistri::Test::McpStubServer.new(tools: ECHO)
    yield server
  ensure
    server.stop
  end

  def remote_client(server, **)
    Mistri::MCP::Client.new(url: server.url,
                            allow_non_public: Mistri::Test::ALLOW_LOOPBACK, **)
  end

  def test_an_error_before_the_call_is_sent_is_tagged_on_a_copy_of_it
    shared = RuntimeError.new("no token").extend(HostTag).freeze
    resolved = 0
    token = -> { [1, 5].include?(resolved += 1) ? raise(shared) : "token" }
    with_server do |server|
      client = remote_client(server, token: token)
      at_the_handshake = assert_raises(RuntimeError) { client.call_tool("echo", {}) }
      at_the_call = assert_raises(RuntimeError) { client.call_tool("echo", {}) }

      assert_kind_of Mistri::MCP::NotSent, at_the_handshake
      assert_equal "no token", at_the_handshake.message
      refute_same shared, at_the_handshake
      assert_kind_of HostTag, at_the_call, "the copy keeps what the host extended its error with"
      assert_kind_of Mistri::MCP::NotSent, at_the_call, "nothing is written before the token"
      assert_equal 5, resolved
      assert_empty server.calls
      refute_kind_of Mistri::MCP::NotSent, shared
    end
  end

  def test_a_call_whose_read_fails_like_a_refused_connection_was_still_sent
    with_server do |server|
      client = remote_client(server)
      client.tools
      Thread.current[:mistri_test_read_error] = Errno::EHOSTUNREACH.new
      error = assert_raises(Mistri::AmbiguousDeliveryError) { client.call_tool("echo", {}) }
      sleep 0.1

      refute_kind_of Mistri::MCP::NotSent, error
      assert_operator server.calls.length, :<=, 1
    end
  ensure
    Thread.current[:mistri_test_read_error] = nil
  end

  def test_the_class_of_an_error_does_not_say_that_no_connection_was_opened
    [Errno::ECONNREFUSED.new, Errno::EHOSTUNREACH.new, Net::OpenTimeout.new].each do |error|
      refute Mistri::Transport.unopened?(error)
    end
  end
end
