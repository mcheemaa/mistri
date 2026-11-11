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

  def test_a_tool_whose_local_name_is_taken_in_the_same_list_is_left_out
    taken = Mistri::MCP.local_name("a.b")
    left_out = []

    tools = Mistri::MCP.tools(client_for(good("a.b"), good(taken), good("search"))) do |tool, error|
      left_out << [tool["name"], error.message]
    end

    assert_equal [taken, "search"], tools.map(&:name)
    assert_equal [[taken, %(MCP tool "#{taken}": the name "#{taken}" is taken by "a.b")]], left_out
    Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns: []), tools:)
  end

  def test_a_name_the_server_lists_twice_is_bridged_once
    left_out = []

    tools = Mistri::MCP.tools(client_for(good("search"), good("search"))) do |tool, _error|
      left_out << tool["name"]
    end

    assert_equal %w[search], tools.map(&:name)
    assert_equal %w[search], left_out
  end

  def test_a_tool_that_was_left_out_does_not_hold_its_name
    tools = Mistri::MCP.tools(client_for(broken, good("broken"))) { |_tool, _error| nil }

    assert_equal %w[broken], tools.map(&:name)
    assert_equal "Does broken.", tools.first.description
  end

  def test_a_definition_that_is_not_an_object_is_left_out
    [nil, "text", 5, [], true].each do |definition|
      left_out = []

      tools = Mistri::MCP.tools(client_for(definition, good("search"))) do |tool, error|
        left_out << [tool, error.message]
      end

      assert_equal %w[search], tools.map(&:name)
      assert_equal [definition], left_out.map(&:first)
      assert_match(/the definition is not an object/, left_out.first.last)
    end
  end

  def test_a_message_carries_only_the_start_of_a_long_remote_name
    long = "x" * 100_000
    messages = []

    _out, err = capture_io do
      Mistri::MCP.tools(client_for(broken.merge("name" => long), good("search")))
    end
    Mistri::MCP.tools(client_for(good(long), good(Mistri::MCP.local_name(long)))) do |_tool, error|
      messages << error.message
    end

    assert_operator err.bytesize, :<, 400
    assert_match(/MCP tool "xxx.*must declare type object.*left out/, err)
    assert_operator messages.first.bytesize, :<, 400
    assert_match(/is taken by "xxx/, messages.first)
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
