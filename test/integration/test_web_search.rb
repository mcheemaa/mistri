# frozen_string_literal: true

require_relative "../support/integration"

# Hosted web search end to end: the agent must reach the live web and carry
# what it found into the answer, with server-tool activity visible as events.
class TestWebSearchIntegration < Minitest::Test
  Integration.scenario(self, :hosted_web_search_reaches_the_answer) do |model|
    agent = Mistri::Agent.new(provider: Mistri.provider(model),
                              tools: [Mistri.web_search],
                              system: "Use web search before answering.")
    events = []

    result = agent.run(
      "Search the web for the current stable Ruby version. Answer in one sentence."
    ) { |event| events << event }

    assert_predicate result, :completed?
    server_types = events.map(&:type).grep(/\Aserver_tool/)

    refute_empty server_types, "expected server tool events from the hosted search"
    assert_match(/ruby/i, result.text)
  end
end
