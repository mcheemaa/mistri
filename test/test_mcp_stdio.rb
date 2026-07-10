# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# The stdio wire: a real spawned child process speaking line-delimited
# JSON-RPC, with credentials in its environment.
class TestMcpStdio < Minitest::Test
  SERVER = <<~'SCRIPT'
    require "json"
    STDOUT.sync = true
    loop do
      line = STDIN.gets or exit
      message = JSON.parse(line)
      if ENV["STUB_TRACE"]
        File.open(ENV["STUB_TRACE"], "a") do |file|
          file.puts([Process.pid, message["method"], message.dig("params", "name")].compact.join(":"))
        end
      end
      next unless message["id"]
      tool = message.dig("params", "name")
      exit if tool == "die"
      puts "not json at all" if tool == "corrupt"
      if message["method"] == "tools/call" && tool == "stall"
        STDOUT.write("{")
        STDOUT.flush
        sleep 60
      end
      if message["method"] == "tools/call" && %w[sized unterminated].include?(tool)
        File.open(ENV["STUB_MARKER"], "a") { |file| file.puts(Process.pid) } if ENV["STUB_MARKER"]
        result = { "content" => [{ "type" => "text", "text" => "" }] }
        response = { "jsonrpc" => "2.0", "id" => message["id"], "result" => result }
        target = Integer(ENV.fetch("STUB_RESPONSE_BYTES"))
        result["content"][0]["text"] = "x" * (target - JSON.generate(response).bytesize)
        encoded = JSON.generate(response)
        raise "bad fixture size" unless encoded.bytesize == target
        if tool == "unterminated"
          STDOUT.write(encoded)
          STDOUT.flush
          sleep 60
        end
        puts encoded
        next
      end
      result =
        case message["method"]
        when "initialize"
          { "protocolVersion" => "2025-11-25", "capabilities" => {},
            "serverInfo" => { "name" => "stdio-stub", "version" => "1" } }
        when "tools/list"
          description = ENV["STUB_LARGE_LIST"] ? "x" * 2000 : "Echoes."
          { "tools" => [{ "name" => "echo", "description" => description,
                          "inputSchema" => { "type" => "object",
                                             "properties" => { "text" => { "type" => "string" } } } }] }
        when "tools/call"
          text = "echo: #{message.dig('params', 'arguments', 'text')} #{ENV['STUB_FLAVOR']}".strip
          { "content" => [{ "type" => "text", "text" => text }] }
        else {}
        end
      puts JSON.generate({ "jsonrpc" => "2.0", "id" => message["id"], "result" => result })
    end
  SCRIPT

  def client(env: {}, read_timeout: 10, max_record_bytes: nil)
    options = { command: ["ruby", "-e", SERVER], env: env, read_timeout: read_timeout }
    options[:max_record_bytes] = max_record_bytes if max_record_bytes
    Mistri::MCP::Client.new(**options)
  end

  def test_the_full_lifecycle_over_a_spawned_process
    stdio = client(env: { "STUB_FLAVOR" => "spiced" })

    assert_equal(["echo"], stdio.tools.map { |t| t["name"] })

    result = stdio.call_tool("echo", { "text" => "hello" })

    assert_equal "echo: hello spiced", result.dig("content", 0, "text"),
                 "arguments flowed out and env credentials flowed in"
  ensure
    stdio.close
  end

  def test_a_bridged_stdio_tool_reaches_an_agent
    stdio = client
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "echo",
                                                              arguments: { "text" => "hi" } }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: Mistri::MCP.tools(stdio))

    result = agent.run("go")

    assert_predicate result, :completed?
    assert_equal "echo: hi", agent.session.messages.select(&:tool?).last.text
  ensure
    stdio.close
  end

  def test_a_dying_server_raises_loudly
    stdio = client
    stdio.connect

    error = assert_raises(Mistri::AmbiguousDeliveryError) { stdio.call_tool("die", {}) }

    assert_kind_of Mistri::MCP::Error, error.cause
    assert_match(/exited|closed/, error.message)
  ensure
    stdio.close
  end

  def test_non_protocol_stdout_raises_loudly
    stdio = client
    stdio.connect

    error = assert_raises(Mistri::AmbiguousDeliveryError) do
      stdio.call_tool("corrupt", {})
    end

    assert_kind_of Mistri::MCP::Error, error.cause
    assert_match(/non-protocol/, error.message)
  ensure
    stdio.close
  end

  def test_accepts_a_stdio_record_at_the_exact_byte_limit
    stdio = client(env: { "STUB_RESPONSE_BYTES" => "512" }, max_record_bytes: 512)

    result = stdio.call_tool("sized", {})

    assert_equal "text", result.dig("content", 0, "type")
  ensure
    stdio.close
  end

  def test_an_oversized_stdio_tool_response_is_ambiguous_and_terminates_the_child
    Dir.mktmpdir do |directory|
      marker = File.join(directory, "calls")
      stdio = client(env: { "STUB_RESPONSE_BYTES" => "513", "STUB_MARKER" => marker },
                     max_record_bytes: 512)

      error = assert_raises(Mistri::AmbiguousDeliveryError) do
        stdio.call_tool("sized", {})
      end

      assert_instance_of Mistri::ResponseTooLargeError, error.cause
      assert_equal :stdio_record, error.cause.kind
      assert_equal 1, File.readlines(marker).length
      pid = File.read(marker).to_i
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    ensure
      stdio&.close
    end
  end

  def test_an_unterminated_stdio_record_fails_as_soon_as_it_crosses_the_limit
    stdio = client(env: { "STUB_RESPONSE_BYTES" => "513" }, max_record_bytes: 512,
                   read_timeout: 10)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Mistri::AmbiguousDeliveryError) do
      stdio.call_tool("unterminated", {})
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_instance_of Mistri::ResponseTooLargeError, error.cause
    assert_operator elapsed, :<, 2
  ensure
    stdio.close
  end

  def test_an_oversized_stdio_tool_list_is_not_ambiguous_or_replayed
    Dir.mktmpdir do |directory|
      trace = File.join(directory, "trace")
      stdio = client(env: { "STUB_LARGE_LIST" => "1", "STUB_TRACE" => trace },
                     max_record_bytes: 512)

      error = assert_raises(Mistri::ResponseTooLargeError) { stdio.tools }
      first_trace = File.readlines(trace, chomp: true)
      list_line = first_trace.find { |line| line.end_with?(":tools/list") }

      assert_equal :stdio_record, error.kind
      assert_equal(1, first_trace.count { |line| line.end_with?(":tools/list") })
      assert_raises(Errno::ESRCH) { Process.kill(0, list_line.to_i) }

      stdio.connect
      pids = File.readlines(trace, chomp: true).map { |line| line.split(":", 2).first }.uniq

      assert_equal 2, pids.length, "the next operation performed a fresh stdio handshake"
    ensure
      stdio&.close
    end
  end

  def test_the_stdio_timeout_covers_the_whole_record
    Dir.mktmpdir do |directory|
      trace = File.join(directory, "trace")
      stdio = client(env: { "STUB_TRACE" => trace }, read_timeout: 0.2)
      stdio.connect
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = assert_raises(Mistri::AmbiguousDeliveryError) do
        stdio.call_tool("stall", {})
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      first_trace = File.readlines(trace, chomp: true)
      tool_pid = first_trace.find { |line| line.end_with?(":tools/call:stall") }.to_i

      assert_kind_of Mistri::MCP::Error, error.cause
      assert_match(/timed out/, error.message)
      assert_operator elapsed, :<, 2
      assert_equal(1, first_trace.count { |line| line.end_with?(":tools/call:stall") })
      assert_raises(Errno::ESRCH) { Process.kill(0, tool_pid) }

      stdio.connect
      pids = File.readlines(trace, chomp: true).map { |line| line.split(":", 2).first }.uniq

      assert_equal 2, pids.length, "the next operation performed a fresh stdio handshake"
    ensure
      stdio&.close
    end
  end

  def test_close_terminates_the_child
    stdio = client
    stdio.connect
    stdio.close

    remaining = `ps -o command= -A`.lines.count { |l| l.include?(SERVER[0, 40]) }

    assert_equal 0, remaining, "no orphaned server process"
  end

  def test_exactly_one_wire_is_required
    assert_raises(Mistri::ConfigurationError) { Mistri::MCP::Client.new }
    assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP::Client.new(url: "https://x.example/mcp", command: ["ruby"])
    end
  end
end
