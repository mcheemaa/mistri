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
      arguments = message.dig("params", "arguments") || {}
      next if tool == "silent"

      sleep arguments["seconds"] if tool == "works"
      if tool == "gone"
        gone = true
        if arguments["notice_after"]
          Thread.new do
            sleep arguments["notice_after"]
            say.call("method" => "notifications/message", "params" => { "data" => "busy" })
          end
        end
        next
      end
      result = case message["method"]
               when "initialize" then { "protocolVersion" => "2025-11-25", "capabilities" => {} }
               when "tools/call" then { "content" => [{ "type" => "text", "text" => tool }] }
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

    _out, reported = capture_io { within(1) { result = @stdio.call_tool("echo", {}) } }

    assert_equal "echo", result.dig("content", 0, "text")
    assert_equal "mistri: the MCP server gave no sign of life after a request with no answer, " \
                 "so it was ended\n", reported
    assert_equal [2, 1, 2], [pids.length, read("ping"), read("initialize")],
                 "the new server got its own handshake"
  end

  def test_a_server_that_is_busy_with_the_request_before_answers_late_and_is_kept
    wire.define_singleton_method(:probe_wait) { 0.05 }
    assert_raises(Mistri::AmbiguousDeliveryError) do
      within(0.2) { @stdio.call_tool("works", { "seconds" => 0.5 }) }
    end

    result = @stdio.call_tool("echo", {})

    assert_equal "echo", result.dig("content", 0, "text")
    assert_equal [1, 1], [pids.length, read("ping")], "it had the read timeout to answer"
  end

  def test_a_server_that_answers_the_question_and_never_a_call_is_kept
    [0.2, 0.5].each do |seconds|
      assert_raises(Timeout::Error) do
        Timeout.timeout(seconds) { @stdio.call_tool("silent", {}) }
      end
    end

    assert_equal [1, 1], [pids.length, read("ping")], "whether to end it is the host's decision"
  end

  def test_a_wait_for_the_whole_answer_is_not_extended_by_another_message
    assert_raises(Timeout::Error) do
      Timeout.timeout(0.05) { @stdio.call_tool("gone", { "notice_after" => 0.35 }) }
    end
    question = { jsonrpc: "2.0", id: 99, method: "ping" }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Mistri::MCP.const_get(:WireTimeout)) do
      Timeout.timeout(5) { wire.call(question, wait: 0.5, whole: true) { |_record| false } }
    end

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.7,
                    "a wait for each message would have ended 0.5 seconds after the notice"
  end

  private

  def lines = File.readlines(@trace, chomp: true).map(&:split)

  def pids = lines.map(&:first).uniq

  def read(method) = lines.count { |_pid, name| name == method }

  def wire = @stdio.instance_variable_get(:@wire)

  # The read timeout for the requests of the block.
  def within(seconds)
    previous = wire.instance_variable_get(:@read_timeout)
    wire.instance_variable_set(:@read_timeout, seconds)
    yield
  ensure
    wire.instance_variable_set(:@read_timeout, previous)
  end
end
