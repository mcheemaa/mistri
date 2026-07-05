# frozen_string_literal: true

require_relative "test_helper"

# The stdio wire: a real spawned child process speaking line-delimited
# JSON-RPC, with credentials in its environment.
class TestMcpStdio < Minitest::Test
  SERVER = <<~'SCRIPT'
    require "json"
    STDOUT.sync = true
    loop do
      line = STDIN.gets or exit
      message = JSON.parse(line)
      next unless message["id"]
      tool = message.dig("params", "name")
      exit if tool == "die"
      puts "not json at all" if tool == "corrupt"
      result =
        case message["method"]
        when "initialize"
          { "protocolVersion" => "2025-06-18", "capabilities" => {},
            "serverInfo" => { "name" => "stdio-stub", "version" => "1" } }
        when "tools/list"
          { "tools" => [{ "name" => "echo", "description" => "Echoes.",
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

  def client(env: {})
    Mistri::MCP::Client.new(command: ["ruby", "-e", SERVER], env: env, read_timeout: 10)
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

    error = assert_raises(Mistri::MCP::Error) { stdio.call_tool("die", {}) }

    assert_match(/exited|closed/, error.message)
  ensure
    stdio.close
  end

  def test_non_protocol_stdout_raises_loudly
    stdio = client
    stdio.connect

    error = assert_raises(Mistri::MCP::Error) { stdio.call_tool("corrupt", {}) }

    assert_match(/non-protocol/, error.message)
  ensure
    stdio.close
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
