# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Which revision a client speaks with a stdio server. A real child process
# plays the server and records the method of every message it reads.
class TestMcpStdioNegotiation < Minitest::Test
  SERVER = <<~'SCRIPT'
    require "json"
    STDOUT.sync = true
    trace = ENV.fetch("STUB_TRACE")
    say = ->(message) { puts JSON.generate({ "jsonrpc" => "2.0" }.merge(message)) }
    once = lambda do |name|
      marker = ENV[name]
      marker && !File.exist?(marker) && File.write(marker, "")
    end
    while (line = STDIN.gets)
      message = JSON.parse(line)
      meta = message.dig("params", "_meta") ? " with _meta" : ""
      File.write(trace, "#{message["method"]}#{meta}\n", mode: "a")
      next unless message.key?("id")

      id = message["id"]
      case message["method"]
      when "server/discover"
        next if ENV["STUB_SILENT"] || once.call("STUB_LATE")
        exit if ENV["STUB_EXITS"]

        say.call("id" => id, "result" => { "supportedVersions" => ["2026-07-28"] })
      when "initialize"
        next if ENV["STUB_MUTE_INITIALIZE"]

        if ENV["STUB_LATE"]
          say.call("id" => id, "error" => { "code" => -32_022, "message" => "Unsupported" })
        elsif ENV["STUB_NEWEST_ONLY"]
          say.call("id" => id, "error" => { "code" => -32_601, "message" => "Method not found" })
        else
          say.call("id" => id, "result" => { "protocolVersion" => "2025-11-25", "capabilities" => {} })
        end
      when "tools/list" then say.call("id" => id, "result" => { "tools" => [] })
      when "tools/call"
        next if message.dig("params", "name") == "silent"

        say.call("id" => id, "result" => { "resultType" => "complete",
                                           "content" => [{ "type" => "text", "text" => "echo" }] })
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

  def test_a_server_that_has_the_newest_revision_gets_no_handshake
    result = client.call_tool("echo", {})

    assert_equal "echo", result.dig("content", 0, "text")
    assert_equal ["server/discover with _meta", "tools/call with _meta"], read
    assert_equal "2026-07-28", @stdio.listing["protocolVersion"]
  end

  def test_a_call_that_times_out_is_cancelled_with_a_notification
    stdio = client(read_timeout: 0.3)
    stdio.tools

    assert_raises(Mistri::AmbiguousDeliveryError) { stdio.call_tool("silent", {}) }
    stdio.call_tool("echo", {})

    assert_includes read, "notifications/cancelled"
    assert_equal ["server/discover with _meta", "tools/call with _meta"], read.last(2),
                 "this revision has no ping, so the sign of life is asked for with its own question"
    refute_includes read, "ping"
  end

  def test_a_server_that_does_not_answer_the_question_gets_the_handshake
    stdio = client(env: { "STUB_SILENT" => "1" }, read_timeout: 0.3)

    assert_equal "echo", stdio.call_tool("echo", {}).dig("content", 0, "text")
    assert_equal ["server/discover with _meta", "notifications/cancelled", "initialize",
                  "notifications/initialized", "tools/call"], read
  end

  def test_a_server_that_exits_at_the_question_is_started_again_for_the_handshake
    stdio = client(env: { "STUB_EXITS" => "1" })

    assert_equal "echo", stdio.call_tool("echo", {}).dig("content", 0, "text")
    assert_equal ["server/discover with _meta", "initialize", "notifications/initialized",
                  "tools/call"], read
  end

  def test_a_server_that_answered_too_late_and_refuses_the_handshake_is_asked_again
    stdio = client(env: { "STUB_LATE" => File.join(@directory, "late") }, read_timeout: 0.3)

    assert_equal "echo", stdio.call_tool("echo", {}).dig("content", 0, "text")
    assert_equal ["server/discover with _meta", "notifications/cancelled", "initialize",
                  "server/discover with _meta", "tools/call with _meta"], read
  end

  def test_a_listing_kept_from_an_older_revision_does_not_pin_a_server_that_left_it
    kept = { "tools" => [{ "name" => "echo" }], "protocolVersion" => "2025-11-25" }
    stdio = client(env: { "STUB_NEWEST_ONLY" => "1" }, listing: kept)

    assert_equal "echo", stdio.call_tool("echo", {}).dig("content", 0, "text")
    assert_equal ["initialize", "server/discover with _meta", "tools/call with _meta"], read
    assert_equal "2026-07-28", stdio.listing(refresh: true)["protocolVersion"]
  end

  def test_a_refusal_from_a_server_that_does_not_answer_the_question_is_raised_as_it_is
    kept = { "tools" => [{ "name" => "echo" }], "protocolVersion" => "2025-11-25" }
    stdio = client(env: { "STUB_NEWEST_ONLY" => "1", "STUB_SILENT" => "1" }, listing: kept,
                   read_timeout: 0.3)

    error = assert_raises(Mistri::MCP::Error) { stdio.call_tool("echo", {}) }

    assert_equal "Method not found", error.message
  end

  def test_a_handshake_that_times_out_is_not_taken_for_a_refusal
    kept = { "tools" => [{ "name" => "echo" }], "protocolVersion" => "2025-11-25" }
    stdio = client(env: { "STUB_MUTE_INITIALIZE" => "1" }, listing: kept, read_timeout: 0.3)

    assert_raises(Mistri::MCP::Error) { stdio.call_tool("echo", {}) }
    assert_equal ["initialize"], read
  end

  private

  def client(env: {}, read_timeout: 10, **)
    @stdio = Mistri::MCP::Client.new(command: ["ruby", "-e", SERVER], read_timeout: read_timeout,
                                     env: env.merge("STUB_TRACE" => @trace), **)
  end

  def read = File.readlines(@trace, chomp: true)
end
