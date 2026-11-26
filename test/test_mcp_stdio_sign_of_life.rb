# frozen_string_literal: true

require_relative "test_helper"
require "timeout"
require "tmpdir"

# A request with no answer leaves a doubt about a stdio server. Before the next
# request the client asks it for a sign of life. A real child process plays the
# server and records the method of every message it reads.
class TestMcpStdioSignOfLife < Minitest::Test
  SERVER = <<~'SCRIPT'
    require "json"
    STDOUT.sync = true
    say = ->(message) { puts JSON.generate({ "jsonrpc" => "2.0" }.merge(message)) }
    gone = false
    while (line = STDIN.gets)
      message = JSON.parse(line)
      File.write(ENV.fetch("STUB_TRACE"), "#{Process.pid} #{message["method"]}\n", mode: "a")
      next if gone || !message.key?("id")

      tool = message.dig("params", "name")
      next if tool == "silent"

      gone = tool == "gone"
      if gone && message.dig("params", "arguments", "chatters")
        Thread.new do
          loop do
            say.call("method" => "notifications/message", "params" => { "data" => "busy" })
            sleep 0.02
          end
        end
      end
      next if gone

      result = case message["method"]
               when "initialize" then { "protocolVersion" => "2025-11-25", "capabilities" => {} }
               when "tools/call" then { "content" => [{ "type" => "text", "text" => "echo" }] }
               else {}
               end
      say.call("id" => message["id"], "result" => result)
    end
  SCRIPT

  def setup
    @directory = Dir.mktmpdir
    @trace = File.join(@directory, "trace")
    @stdio = Mistri::MCP::Client.new(command: ["ruby", "-e", SERVER], read_timeout: 10,
                                     env: { "STUB_TRACE" => @trace })
    @stdio.connect
  end

  def teardown
    @stdio.close
    FileUtils.remove_entry(@directory)
  end

  def test_a_server_that_gives_no_sign_of_life_is_ended_before_the_next_request
    assert_raises(Mistri::AmbiguousDeliveryError) { within(0.2) { @stdio.call_tool("gone", {}) } }
    result = nil

    _out, reported = capture_io { asked_for(0.3) { result = @stdio.call_tool("echo", {}) } }

    assert_equal "echo", result.dig("content", 0, "text")
    assert_equal "mistri: the MCP server gave no sign of life after a request with no answer, " \
                 "so it was ended\n", reported
    assert_equal [2, 1, 2], [pids.length, read("ping"), read("initialize")],
                 "the new server got its own handshake"
  end

  def test_messages_that_are_not_the_answer_do_not_extend_the_wait_for_it
    assert_raises(Timeout::Error) do
      Timeout.timeout(0.2) { @stdio.call_tool("gone", { "chatters" => true }) }
    end

    capture_io { Timeout.timeout(5) { asked_for(0.3) { @stdio.call_tool("echo", {}) } } }

    assert_equal 2, pids.length
  end

  def test_a_server_that_answers_the_question_and_never_a_call_is_kept
    2.times do
      assert_raises(Mistri::AmbiguousDeliveryError) do
        within(0.2) { @stdio.call_tool("silent", {}) }
      end
    end

    assert_equal [1, 1], [pids.length, read("ping")], "whether to end it is the host's decision"
  end

  private

  def lines = File.readlines(@trace, chomp: true).map(&:split)

  def pids = lines.map(&:first).uniq

  def read(method) = lines.count { |_pid, name| name == method }

  def wire = @stdio.instance_variable_get(:@wire)

  # The read timeout for one call, never for a server that starts.
  def within(seconds)
    previous = wire.instance_variable_get(:@read_timeout)
    wire.instance_variable_set(:@read_timeout, seconds)
    yield
  ensure
    wire.instance_variable_set(:@read_timeout, previous)
  end

  # The wait for a sign of life, without the wait for a new server to start.
  def asked_for(seconds)
    wire.define_singleton_method(:probe_wait) { seconds }
    yield
  ensure
    wire.singleton_class.remove_method(:probe_wait)
  end
end
