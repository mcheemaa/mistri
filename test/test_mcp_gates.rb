# frozen_string_literal: true

require_relative "test_helper"

# A host names the tools that wait for a person. A name that matches no tool
# would leave the tool it was meant for to run without one.
class TestMcpGates < Minitest::Test
  def client = Struct.new(:tools).new([{ "name" => "create", "description" => "Creates." }])

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
end
