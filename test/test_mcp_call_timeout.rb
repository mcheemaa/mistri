# frozen_string_literal: true

require_relative "test_helper"

# The limit on one call of a bridged tool, which the tool executor enforces.
class TestMcpCallTimeout < Minitest::Test
  def test_a_bridged_tool_has_a_limit_for_one_call
    listed = [{ "name" => "search", "description" => "Searches." }]
    client = Struct.new(:tools).new(listed)

    assert_equal 300, Mistri::MCP::CALL_TIMEOUT
    assert_equal [300], Mistri::MCP.tools(client).map(&:timeout)
    assert_equal [20], Mistri::MCP.tools(client, timeout: 20).map(&:timeout)
    assert_equal [nil], Mistri::MCP.tools(client, timeout: nil).map(&:timeout)
    assert_equal 300, Mistri::MCP.bridge(client, listed.first).timeout
    assert_nil Mistri::MCP.bridge(client, listed.first, timeout: nil).timeout
  end
end
