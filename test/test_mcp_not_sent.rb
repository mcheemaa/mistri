# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_stub_server"

# An error that Client#call_tool raises before the call is sent is raised as a
# copy tagged NotSent. The error a caller owns is never changed.
class TestMcpNotSent < Minitest::Test
  ECHO = { "echo" => { description: "Echoes.", handler: ->(_args) { "echo" } } }.freeze

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
    shared = RuntimeError.new("no token").freeze
    resolved = 0
    token = -> { [1, 4].include?(resolved += 1) ? raise(shared) : "token" }
    with_server do |server|
      client = remote_client(server, token: token)
      unsent = assert_raises(RuntimeError) { client.call_tool("echo", {}) }
      attempted = assert_raises(RuntimeError) { client.call_tool("echo", {}) }

      assert_kind_of Mistri::MCP::NotSent, unsent
      assert_equal ["no token", shared.backtrace], [unsent.message, unsent.backtrace]
      assert_same shared, attempted
      refute_kind_of Mistri::MCP::NotSent, shared
    end
  end

  def test_an_error_that_cannot_be_copied_is_raised_untagged
    copies = [->(_) { raise TypeError, "cannot copy" }, lambda(&:itself), ->(_) { "replacement" }]
    with_server do |server|
      copies.each do |copy|
        error = Class.new(StandardError) { define_method(:dup) { copy.call(self) } }.new("no token")
        raised = assert_raises(StandardError) do
          remote_client(server, token: -> { raise error }).call_tool("echo", {})
        end

        assert_same error, raised
        refute_kind_of Mistri::MCP::NotSent, raised
      end
    end
  end
end
