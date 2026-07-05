# frozen_string_literal: true

require_relative "../support/integration"

# The MCP bridge against a real public server: the client speaks the live
# protocol and the agent answers through a bridged tool. Uses DeepWiki, an
# open Streamable HTTP server; skips gracefully if it is unreachable.
class TestMcpIntegration < Minitest::Test
  Integration.scenario(self, :agent_answers_through_a_live_mcp_server) do |model|
    client = Mistri::MCP::Client.new(url: "https://mcp.deepwiki.com/mcp")
    begin
      begin
        client.connect
      rescue Mistri::Error => e
        skip "DeepWiki MCP unreachable: #{e.message}"
      end

      names = client.tools.map { |t| t["name"] }

      assert_includes names, "read_wiki_structure"

      called = []
      bridged = Mistri::MCP.tools(client, allow: ["read_wiki_structure"], prefix: "deepwiki")
      agent = Mistri::Agent.new(provider: Mistri.provider(model), tools: bridged,
                                system: "Use the deepwiki tool to answer. Be brief.")

      result = agent.run("What documentation topics exist for the " \
                         "modelcontextprotocol/ruby-sdk repo? Name two.") do |event|
        called << event.tool_call.name if event.type == :tool_result
      end

      assert_predicate result, :completed?
      assert_includes called, "deepwiki__read_wiki_structure",
                      "the agent never used the live MCP tool"
      assert_operator result.text.to_s.length, :>, 20
    ensure
      client.close
    end
  end
end
