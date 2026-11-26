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
    notice = { "method" => "notifications/message", "params" => { "data" => "busy" } }
    line_of = ->(message) { "#{JSON.generate({ "jsonrpc" => "2.0" }.merge(message))}\n" }
    say = ->(*messages) { STDOUT.write(messages.map(&line_of).join) }
    gone = noisy = false
    while (line = STDIN.gets)
      message = JSON.parse(line)
      File.write(ENV.fetch("STUB_TRACE"), "#{Process.pid} #{message["method"]}\n", mode: "a")
      next if gone || !message.key?("id")

      tool = message.dig("params", "name")
      arguments = message.dig("params", "arguments") || {}
      case tool
      when "silent" then next
      when "noisy"
        noisy = true
        next
      when "works" then sleep arguments["seconds"]
      when "gone"
        gone = true
        if arguments["notices"]
          Thread.new do
            loop do
              sleep 0.1
              say.call(notice)
            end
          end
        end
        next
      end
      result = case message["method"]
               when "initialize" then { "protocolVersion" => "2025-11-25", "capabilities" => {} }
               when "tools/call" then { "content" => [{ "type" => "text", "text" => tool }] }
               else {}
               end
      answer = { "id" => message["id"], "result" => result }
      noisy ? say.call(notice, answer) : say.call(answer)
    end
  SCRIPT

  def setup
    @directory = Dir.mktmpdir
    @trace = File.join(@directory, "trace")
    @pause = 0
    @stdio = Mistri::MCP::Client.new(command: ["ruby", "-e", SERVER], read_timeout: 10,
                                     env: { "STUB_TRACE" => @trace },
                                     on_notification: ->(*) { sleep @pause })
    @stdio.connect
  end

  def teardown
    @stdio.close
    FileUtils.remove_entry(@directory)
  end

  def test_a_server_that_gives_no_sign_of_life_is_ended_before_the_next_request
    assert_raises(Timeout::Error) do
      Timeout.timeout(0.3) { @stdio.call_tool("gone", { "notices" => true }) }
    end
    result = nil

    _out, reported = capture_io do
      Timeout.timeout(5) { within(1) { result = @stdio.call_tool("echo", {}) } }
    end

    assert_equal "echo", text_of(result)
    assert_equal "mistri: the MCP server gave no sign of life after a request with no answer, " \
                 "so it was ended\n", reported
    assert_equal [2, 1, 2], [pids.length, read("ping"), read("initialize")],
                 "its notices did not extend the wait, and the new server got its own handshake"
  end

  def test_a_server_that_is_busy_with_the_request_before_answers_late_and_is_kept
    wire.define_singleton_method(:probe_wait) { 0.05 }
    assert_raises(Mistri::AmbiguousDeliveryError) do
      within(0.2) { @stdio.call_tool("works", { "seconds" => 0.5 }) }
    end

    assert_equal "echo", text_of(@stdio.call_tool("echo", {}))
    assert_equal [1, 1], [pids.length, read("ping")], "it had the read timeout to answer"
  end

  def test_a_server_asked_long_after_the_request_still_has_the_wait_for_one_question
    within(0.4) do
      assert_raises(Mistri::AmbiguousDeliveryError) { @stdio.call_tool("silent", {}) }
      sleep 0.5

      assert_equal "echo", text_of(@stdio.call_tool("echo", {}))
    end
    assert_equal [1, 1], [pids.length, read("ping")]
  end

  def test_a_call_with_a_shorter_limit_of_its_own_still_ends_a_server_that_is_gone
    wire.define_singleton_method(:probe_wait) { 0.1 }
    answers = nil

    _out, reported = capture_io do
      within(1) do
        assert_nil limited(0.1) { @stdio.call_tool("gone", {}) }
        answers = Array.new(6) { limited(0.4) { @stdio.call_tool("echo", {}) } }
      end
    end

    assert_nil answers.first, "the limit ended a question that had the read timeout"
    assert_equal ["echo"], answers.compact.map { |answer| text_of(answer) }.uniq
    assert_match(/gave no sign of life/, reported)
    assert_equal 2, pids.length
  end

  def test_without_a_read_timeout_the_question_has_no_limit_of_its_own
    within(nil) { 2.times { assert_nil limited(0.2) { @stdio.call_tool("gone", {}) } } }

    assert_equal [1, 1, 1], [pids.length, read("ping"), read("tools/call")],
                 "only the host ends such a server"
  end

  def test_the_time_the_host_takes_for_a_notice_does_not_end_a_server_that_answered
    within(0.2) do
      assert_raises(Mistri::AmbiguousDeliveryError) { @stdio.call_tool("noisy", {}) }
      @pause = 0.4

      assert_equal "echo", text_of(@stdio.call_tool("echo", {}))
    end
    assert_equal [1, 1], [pids.length, read("ping")], "its answer came in one write with a notice"
  end

  def test_a_server_that_answers_the_question_and_never_a_call_is_kept
    [0.2, 0.5].each { |seconds| assert_nil limited(seconds) { @stdio.call_tool("silent", {}) } }

    assert_equal [1, 1], [pids.length, read("ping")], "whether to end it is the host's decision"
  end

  private

  def lines = File.readlines(@trace, chomp: true).map(&:split)

  def pids = lines.map(&:first).uniq

  def read(method) = lines.count { |_pid, name| name == method }

  def text_of(result) = result.dig("content", 0, "text")

  def wire = @stdio.instance_variable_get(:@wire)

  # The read timeout for the requests of the block.
  def within(seconds)
    previous = wire.instance_variable_get(:@read_timeout)
    wire.instance_variable_set(:@read_timeout, seconds)
    yield
  ensure
    wire.instance_variable_set(:@read_timeout, previous)
  end

  # What the block returns, or nil when the caller's own limit ended it.
  def limited(seconds, &)
    Timeout.timeout(seconds, &)
  rescue Timeout::Error
    nil
  end
end
