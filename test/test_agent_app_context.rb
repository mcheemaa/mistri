# frozen_string_literal: true

require_relative "test_helper"

# The host's context object rides the run: whatever Agent.new(context:)
# received reaches every tool handler and hook as context.app, untouched.
class TestAgentAppContext < Minitest::Test
  def provider
    Mistri::Providers::Fake.new(turns: [
                                  { tool_calls: [{ name: "whoami", arguments: {} }] },
                                  { text: "done" }
                                ])
  end

  def test_handlers_read_the_hosts_context_through_the_slot
    seen = nil
    tool = Mistri::Tool.define("whoami", "Names the traveler.") do |_args, context|
      seen = context.app
      "ok"
    end
    traveler = { name: "Dana", tier: "gold" }
    agent = Mistri::Agent.new(provider: provider, tools: [tool], context: traveler)

    agent.run("who am I")

    assert_same traveler, seen, "the host object arrives untouched"
  end

  def test_hooks_see_the_same_context
    seen = []
    policy = lambda do |_call, context|
      seen << context.app
      nil
    end
    audit = lambda do |_call, _result, context|
      seen << context.app
      nil
    end
    tool = Mistri::Tool.define("whoami", "W.") { "ok" }
    agent = Mistri::Agent.new(provider: provider, tools: [tool], context: :tenant_west,
                              before_tool: policy, after_tool: audit)

    agent.run("go")

    assert_equal %i[tenant_west tenant_west], seen
  end

  def test_the_slot_defaults_to_nil
    seen = :unset
    tool = Mistri::Tool.define("whoami", "W.") do |_args, context|
      seen = context.app
      "ok"
    end

    Mistri::Agent.new(provider: provider, tools: [tool]).run("go")

    assert_nil seen
  end
end
