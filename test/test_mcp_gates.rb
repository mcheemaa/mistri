# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"

# A host names the tools that wait for a person. A name that matches no tool
# would leave the tool it was meant for to run without one.
class TestMcpGates < Minitest::Test
  NEWEST = { "supportedVersions" => ["2026-07-28"] }.freeze
  # A header mark on a number breaks the rules of 2026-07-28, so a client
  # over HTTP leaves the tool out.
  BROKEN = { "name" => "purge", "inputSchema" => {
    "type" => "object", "properties" => { "count" => { "type" => "number", "x-mcp-header" => "N" } }
  } }.freeze

  # A host's own client. It may name the tools it left out, and this one names none.
  def client
    Struct.new(:tools, :left_out).new([{ "name" => "create", "description" => "Creates." }])
  end

  def test_a_key_that_names_no_tool_is_refused
    [{ create: true }, { "creat" => true }].each do |gates|
      error = assert_raises(Mistri::ConfigurationError) { Mistri::MCP.tools(client, gates: gates) }

      assert_equal "gates: names no tool of this server: #{gates.keys.first.inspect}", error.message
    end
  end

  def test_a_key_that_names_a_tool_gates_it_also_when_the_host_leaves_that_tool_out
    assert Mistri::MCP.tools(client, gates: { "create" => true }).first.needs_approval?({})
    assert_empty Mistri::MCP.tools(client, deny: ["create"], gates: { "create" => true })
  end

  def test_a_key_may_name_a_tool_the_client_left_out_also_from_a_stored_listing
    listed = [{ "name" => "search" }, BROKEN]
    server = Mistri::Test::McpScriptedServer.new(discover: NEWEST, listed: listed)
    build = lambda do |**options|
      Mistri::MCP::Client.new(url: server.url, allow_non_public: Mistri::Test::ALLOW_LOOPBACK,
                              **options)
    end
    keys = { gates: { "purge" => true }, parallel: { "purge" => false } }
    fresh = build.call
    bridged = kept = nil
    capture_io do
      bridged = Mistri::MCP.tools(fresh, **keys)
      kept = JSON.parse(JSON.generate(fresh.listing))
    end
    stored = build.call(listing: kept)

    assert_equal %w[search], bridged.map(&:name)
    assert_equal [%w[purge], %w[purge]], [fresh.left_out, stored.left_out]
    assert_equal %w[search], Mistri::MCP.tools(stored, **keys).map(&:name)
    assert_empty server.sent("tools/call")

    listed.pop
    fresh.tools(refresh: true)

    assert_empty fresh.left_out, "a fresh listing holds only what the server lists now"
  ensure
    [fresh, stored].each { |built| built&.close }
    server&.stop
  end
end
