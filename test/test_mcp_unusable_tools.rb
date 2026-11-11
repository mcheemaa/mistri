# frozen_string_literal: true

require_relative "test_helper"

# One tool a server lists that cannot be bridged is left out and reported.
# The rest of the server's tools stay usable.
class TestMcpUnusableTools < Minitest::Test
  def client_for(*listed) = Struct.new(:tools).new(listed)

  def good(name) = { "name" => name, "description" => "Does #{name}." }

  def broken = { "name" => "broken", "description" => "Broken.", "inputSchema" => false }

  def test_a_tool_that_cannot_be_bridged_is_left_out_and_the_rest_stay
    left_out = []

    tools = Mistri::MCP.tools(client_for(good("search"), broken, good("create"))) do |tool, error|
      left_out << [tool["name"], error]
    end

    assert_equal %w[search create], tools.map(&:name)
    assert_equal ["broken"], left_out.map(&:first)
    assert_kind_of Mistri::ConfigurationError, left_out.first.last
    assert_match(/MCP tool "broken".*must declare type object/, left_out.first.last.message)
  end

  def test_without_a_block_the_tool_that_was_left_out_is_named_in_a_warning
    tools = nil

    _out, err = capture_io { tools = Mistri::MCP.tools(client_for(broken, good("search"))) }

    assert_equal %w[search], tools.map(&:name)
    assert_match(/mistri: MCP tool "broken".*must declare type object.*left out/, err)
  end

  def test_a_tool_without_a_name_is_left_out
    left_out = []
    nameless = { "description" => "No name." }

    tools = Mistri::MCP.tools(client_for(nameless, good("search"))) { |tool, _| left_out << tool }

    assert_equal %w[search], tools.map(&:name)
    assert_equal [nameless], left_out
  end

  def test_a_host_that_wants_the_old_behaviour_raises_from_the_block
    assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP.tools(client_for(good("search"), broken)) { |_tool, error| raise error }
    end
  end

  def test_bridging_one_definition_still_raises
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP.bridge(client_for, broken)
    end

    assert_match(/MCP tool "broken"/, error.message)
  end
end
