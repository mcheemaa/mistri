# frozen_string_literal: true

require_relative "test_helper"
require "timeout"
require "tmpdir"

# What a stdio server does besides answer: it asks, goes silent, answers late,
# writes a stray line, or will not end. A real child process plays the server
# and records every line it reads.
class TestMcpStdioConversation < Minitest::Test
  SERVER = <<~'SCRIPT'
    require "json"
    STDOUT.sync = true
    trace = ENV.fetch("STUB_TRACE")
    note = ->(text) { File.write(trace, "#{Process.pid} #{text}\n", mode: "a") }
    say = ->(message) { puts JSON.generate({ "jsonrpc" => "2.0" }.merge(message)) }
    text = ->(body) { { "content" => [{ "type" => "text", "text" => body }] } }
    once = lambda do |name|
      marker = ENV[name]
      marker && !File.exist?(marker) && File.write(marker, "")
    end
    Signal.trap("TERM") do
      note.call("SIGTERM")
      exit unless ENV["STUB_IGNORE_TERM"]
    end
    loop do
      line = STDIN.gets
      unless line
        note.call("input closed")
        loop { sleep 1 } if ENV["STUB_IGNORE_EOF"]
        exit
      end
      note.call(line.strip[0, 300])
      message = JSON.parse(line)
      next unless message["method"] && message.key?("id")

      id = ENV["STUB_STRING_IDS"] ? message["id"].to_s : message["id"]
      arguments = message.dig("params", "arguments") || {}
      case message["method"] == "tools/call" ? message.dig("params", "name") : message["method"]
      when "initialize"
        next if ENV["STUB_MUTE_INITIALIZE"]

        say.call("id" => id, "result" => { "protocolVersion" => "2025-11-25", "capabilities" => {},
                                           "serverInfo" => { "name" => "stub", "version" => "1" } })
      when "tools/list"
        next if once.call("STUB_MUTE_FIRST_LIST")

        say.call("id" => id, "result" => { "tools" => [{ "name" => "echo" }] })
        sleep if once.call("STUB_DEAF_AFTER_LIST")
        sleep 0.3 if once.call("STUB_READS_LATE")
      when "asks"
        STDIN.reopen(File::NULL) if arguments["deaf"]
        say.call("id" => arguments.fetch("id", message["id"]), "method" => arguments["method"])
        note.call(STDIN.gets.strip) if arguments["awaits"]
        say.call("id" => id, "result" => text.call("asked"))
        exit if arguments["deaf"]
      when "silent"
        next unless arguments["deaf"]

        STDIN.reopen(File::NULL)
        sleep
      when "big"
        begin
          puts "x" * 300_000
        rescue Errno::EPIPE
          sleep
        end
      when "late"
        sleep 0.4
        say.call("id" => id, "result" => text.call("late"))
      when "fails"
        say.call("id" => id, "error" => { "code" => -32_602, "message" => "Unknown tool" })
      when "noise"
        puts "Debugger listening on a port"
        puts "[1, 2]"
        say.call("id" => id, "result" => text.call("after the noise"))
      else
        say.call("id" => id, "result" => text.call("echo: #{arguments["text"].to_s[0, 20]}"))
      end
    end
  SCRIPT

  def setup
    @directory = Dir.mktmpdir
    @trace = File.join(@directory, "trace")
  end

  def teardown
    @stdio&.close
    FileUtils.remove_entry(@directory)
  end

  def test_a_ping_from_the_server_is_answered_while_a_call_waits
    result = client.call_tool("asks", { "method" => "ping", "id" => "srv-1", "awaits" => true })

    assert_equal "asked", result.dig("content", 0, "text")
    assert_includes sent, { "jsonrpc" => "2.0", "id" => "srv-1", "result" => {} }
  end

  def test_any_other_request_from_the_server_is_refused
    client.call_tool("asks", { "method" => "sampling/createMessage", "id" => 7, "awaits" => true })

    assert_includes sent, { "jsonrpc" => "2.0", "id" => 7,
                            "error" => { "code" => -32_601, "message" => "Method not found" } }
  end

  def test_a_request_with_the_id_of_the_call_is_not_its_answer
    result = client.call_tool("asks", { "method" => "ping", "awaits" => true })

    assert_equal "asked", result.dig("content", 0, "text")
    assert_equal({}, sent.last["result"])
  end

  def test_a_request_with_an_id_that_is_not_a_string_or_an_integer_gets_no_reply
    stdio = client
    stdio.call_tool("asks", { "method" => "ping", "id" => nil })
    stdio.call_tool("echo", {})

    assert_empty(sent.select { |message| message.key?("result") || message.key?("error") })
  end

  def test_a_reply_that_cannot_be_written_does_not_fail_the_call
    result = client.call_tool("asks", { "method" => "ping", "id" => "srv-1", "deaf" => true })

    assert_equal "asked", result.dig("content", 0, "text")
  end

  def test_a_timeout_cancels_the_call_and_keeps_the_server
    stdio = client
    stdio.connect

    error = assert_raises(Mistri::AmbiguousDeliveryError) do
      with_read_timeout(stdio, 0.2) { stdio.call_tool("late", {}) }
    end
    result = stdio.call_tool("echo", { "text" => "mine" })

    assert_match(/timed out waiting for the MCP server/, error.message)
    assert_equal "echo: mine", result.dig("content", 0, "text"), "the late answer was not taken"
    assert_equal [{ "requestId" => called("tools/call"), "reason" => "timed out" }], cancels
    assert_equal 1, pids.length
    assert_equal 1, asked("ping"), "it answered the question, so it was slow and not gone"
  end

  def test_a_list_that_times_out_is_cancelled_and_can_be_asked_again
    stdio = client(env: { "STUB_MUTE_FIRST_LIST" => File.join(@directory, "muted") })
    stdio.connect

    error = assert_raises(Mistri::MCP::Error) { with_read_timeout(stdio, 0.2) { stdio.tools } }

    assert_match(/timed out/, error.message)
    assert_equal(["echo"], stdio.tools.map { |tool| tool["name"] })
    assert_equal([called("tools/list")], cancels.map { |params| params["requestId"] })
    assert_equal [1, 1], [pids.length, asked("ping")]
  end

  def test_the_handshake_is_never_cancelled
    stdio = client(env: { "STUB_MUTE_INITIALIZE" => "1" }, read_timeout: 0.3)

    assert_raises(Mistri::MCP::Error) { stdio.connect }

    assert_empty cancels
    assert_includes File.read(@trace), "input closed"
  end

  def test_a_cancel_that_cannot_be_written_still_ends_the_call
    stdio = client
    stdio.connect

    error = assert_raises(Mistri::AmbiguousDeliveryError) do
      with_read_timeout(stdio, 0.2) { stdio.call_tool("silent", { "deaf" => true }) }
    end

    assert_match(/timed out/, error.message)
  end

  def test_a_caller_that_stops_waiting_cancels_the_call_and_keeps_the_server
    stdio = client
    stdio.connect

    assert_raises(Timeout::Error) { Timeout.timeout(0.2) { stdio.call_tool("silent", {}) } }
    result = stdio.call_tool("echo", { "text" => "next" })

    stopped = { "requestId" => called("tools/call"), "reason" => "the caller stopped waiting" }

    assert_equal "echo: next", result.dig("content", 0, "text")
    assert_equal [stopped], cancels
    assert_equal [1, 1], [pids.length, asked("ping")]
  end

  def test_an_error_from_the_server_is_raised_and_nothing_is_cancelled
    stdio = client

    error = assert_raises(Mistri::MCP::Error) { stdio.call_tool("fails", {}) }
    stdio.call_tool("echo", {})

    assert_equal "Unknown tool", error.message
    assert_equal(-32_602, error.code)
    assert_empty cancels
  end

  def test_an_id_that_comes_back_as_a_string_is_matched
    stdio = client(env: { "STUB_STRING_IDS" => "1" })

    assert_equal(["echo"], stdio.tools.map { |tool| tool["name"] })
    assert_equal "echo: hi", stdio.call_tool("echo", { "text" => "hi" }).dig("content", 0, "text")
  end

  def test_a_line_that_is_not_json_is_skipped_and_reported
    stdio = client
    stdio.connect
    result = nil

    _out, reported = capture_io { result = stdio.call_tool("noise", {}) }

    assert_equal "after the noise", result.dig("content", 0, "text")
    assert_equal "mistri: the MCP server wrote a line that is not JSON: " \
                 "\"Debugger listening on a port\"\n", reported
  end

  def test_a_call_to_a_server_that_has_stopped_reading_ends_at_the_read_timeout
    stdio = client(env: { "STUB_DEAF_AFTER_LIST" => File.join(@directory, "deaf") })
    stdio.tools
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Mistri::AmbiguousDeliveryError) do
      with_read_timeout(stdio, 0.3) { stdio.call_tool("echo", { "text" => "x" * 300_000 }) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    result = stdio.call_tool("echo", { "text" => "next" })

    assert_match(/timed out/, error.message)
    assert_operator elapsed, :<, 2
    assert_equal "echo: next", result.dig("content", 0, "text")
    assert_equal 2, pids.length, "half a message was left in the first server's input"
    assert_equal 2, sent.count { |message| message["method"] == "initialize" },
                 "the new server got its own handshake"
    assert_empty cancels
  end

  def test_a_large_call_waits_for_a_server_that_reads_late
    stdio = client(env: { "STUB_READS_LATE" => File.join(@directory, "late") })
    stdio.tools

    result = stdio.call_tool("echo", { "text" => "x" * 300_000 })

    assert_equal "echo: #{"x" * 20}", result.dig("content", 0, "text")
  end

  def test_a_message_that_may_not_wait_is_dropped_when_the_pipe_is_full
    reader, writer = IO.pipe
    nil while writer.write_nonblock("x" * 65_536, exception: false) != :wait_writable
    wire = Mistri::MCP::Wires::Stdio.new(command: ["unused"])
    wire.instance_variable_set(:@stdin, writer)
    wire.instance_variable_set(:@pid, Process.pid)

    assert_raises(Mistri::MCP.const_get(:WireTimeout)) do
      wire.notify({ jsonrpc: "2.0", method: "notifications/cancelled" }, wait: 0)
    end
    assert_predicate wire, :open?, "nothing was written, so the wire is whole"
  ensure
    [reader, writer].each(&:close)
  end

  def test_a_cancel_does_not_wait_for_a_server_that_has_stopped_reading
    reader, writer = IO.pipe
    nil while writer.write_nonblock("x" * 65_536, exception: false) != :wait_writable
    wire = Mistri::MCP::Wires::Stdio.new(command: ["unused"], read_timeout: 5)
    wire.instance_variable_set(:@stdin, writer)
    wire.instance_variable_set(:@pid, Process.pid)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Mistri::MCP.const_get(:WireTimeout)) do
      wire.cancel({ jsonrpc: "2.0", method: "notifications/cancelled" })
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  ensure
    [reader, writer].each(&:close)
  end

  def test_a_caller_that_stops_waiting_while_a_server_is_ended_gets_its_own_error
    stubborn = { "STUB_TRACE" => @trace, "STUB_IGNORE_EOF" => "1", "STUB_IGNORE_TERM" => "1" }
    @stdio = Mistri::MCP::Client.new(command: ["ruby", "-e", SERVER], env: stubborn,
                                     read_timeout: 10, max_record_bytes: 100_000)
    @stdio.connect

    assert_raises(Timeout::Error) { Timeout.timeout(0.3) { @stdio.call_tool("big", {}) } }
    result = @stdio.call_tool("echo", { "text" => "next" })

    assert_equal "echo: next", result.dig("content", 0, "text")
    assert_equal 2, pids.length, "the server whose close was ended early was ended, then replaced"
    assert_raises(Errno::ESRCH) { Process.kill(0, pids.first.to_i) }
  end

  def test_a_client_with_no_read_timeout_waits_without_one
    stdio = client(read_timeout: nil)

    assert_equal "echo: hi", stdio.call_tool("echo", { "text" => "hi" }).dig("content", 0, "text")
  end

  def test_close_lets_the_server_end_by_itself
    client.connect
    @stdio.close

    assert_equal ["input closed"], endings
  end

  def test_close_sends_sigterm_to_a_server_that_does_not_end
    client(env: { "STUB_IGNORE_EOF" => "1" }).connect
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @stdio.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal ["input closed", "SIGTERM"], endings
    assert_operator elapsed, :>=, 0.5
    assert_operator elapsed, :<, 1.4
  end

  def test_close_kills_a_server_that_ignores_sigterm
    client(env: { "STUB_IGNORE_EOF" => "1", "STUB_IGNORE_TERM" => "1" }).connect
    pid = pids.first.to_i
    @stdio.close

    assert_equal ["input closed", "SIGTERM"], endings
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  private

  def client(env: {}, read_timeout: 10)
    @stdio = Mistri::MCP::Client.new(command: ["ruby", "-e", SERVER], read_timeout: read_timeout,
                                     env: env.merge("STUB_TRACE" => @trace))
  end

  def lines = File.readlines(@trace, chomp: true).map { |line| line.split(" ", 2) }

  def pids = lines.map(&:first).uniq

  def endings = lines.map(&:last).grep(/\A(input closed|SIGTERM)\z/)

  # Every message the server read from the client.
  def sent = lines.map(&:last).grep(/\A\{/).map { |line| JSON.parse(line) }

  def cancels
    sent.select { |message| message["method"] == "notifications/cancelled" }
        .map { |message| message["params"] }
  end

  def called(method) = sent.find { |message| message["method"] == method }["id"]

  def asked(method) = sent.count { |message| message["method"] == method }

  # Only the one call gets the short deadline, never process startup.
  def with_read_timeout(client, seconds)
    wire = client.instance_variable_get(:@wire)
    previous = wire.instance_variable_get(:@read_timeout)
    wire.instance_variable_set(:@read_timeout, seconds)
    yield
  ensure
    wire.instance_variable_set(:@read_timeout, previous)
  end
end
