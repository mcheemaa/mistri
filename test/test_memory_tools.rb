# frozen_string_literal: true

require_relative "test_helper"

class TestMemoryTools < Minitest::Test
  def setup
    @record = { memory: "" }
    store = Mistri::Memory.new(read: -> { @record[:memory] },
                               write: ->(text) { @record[:memory] = text })
    @tools = Mistri::Tools.memory(store).to_h { |tool| [tool.name, tool] }
  end

  def test_empty_memory_reads_as_guidance
    assert_equal "Memory is empty.", @tools["read_memory"].call({})
  end

  def test_update_replaces_the_whole_document
    @tools["update_memory"].call({ "content" => "Brand voice: warm, direct." })

    assert_equal "Brand voice: warm, direct.", @record[:memory]
    assert_equal "Brand voice: warm, direct.", @tools["read_memory"].call({})

    @tools["update_memory"].call({ "content" => "Rewritten." })

    assert_equal "Rewritten.", @record[:memory]
  end

  def test_an_agent_can_carry_knowledge_across_sessions
    turn = { tool_calls: [{ name: "update_memory", arguments: { "content" => "Learned: X" } }] }
    provider = Mistri::Providers::Fake.new(turns: [turn, { text: "noted" }])
    agent = Mistri::Agent.new(provider:, tools: Mistri::Tools.memory(
      Mistri::Memory.new(read: -> { @record[:memory] },
                         write: ->(text) { @record[:memory] = text })
    ))

    agent.run("Remember X")

    assert_equal "Learned: X", @record[:memory]
  end
end
