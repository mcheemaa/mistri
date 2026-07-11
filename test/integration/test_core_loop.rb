# frozen_string_literal: true

require_relative "../support/integration"

# The loop end to end: generated facts must travel through tool results into
# the answer, and the ui side-channel must reach the host and never the model.
class TestCoreLoopIntegration < Minitest::Test
  Integration.scenario(self, :tools_carry_generated_facts) do |model|
    founder = Integration.codename
    city = Integration.codename
    founder_tool = Mistri::Tool.define("founder_name", "The company founder's name.") { founder }
    hq_tool = Mistri::Tool.define("hq_city", "The company's HQ city name.") { city }
    agent = Mistri::Agent.new(provider: Mistri.provider(model),
                              tools: [founder_tool, hq_tool],
                              system: "Answer strictly from the tools.")

    result = agent.run("Who founded the company and what city is HQ in? One sentence.")

    assert_predicate result, :completed?
    assert Integration.saw?(result.text, founder), "founder fact never flowed: #{result.text}"
    assert Integration.saw?(result.text, city), "city fact never flowed: #{result.text}"
  end

  Integration.scenario(self, :ui_channel_reaches_host_not_model) do |model|
    revision = Integration.codename
    save = Mistri::Tool.define("save_page", "Saves the current page draft.") do
      Mistri::ToolResult.new(content: "Saved.", ui: { "revision" => revision })
    end
    seen_ui = []
    agent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [save],
                              system: "Save the page when asked, then confirm briefly.")

    result = agent.run("Save the page.") do |event|
      seen_ui << event.message.ui if event.type == :tool_result && event.message.ui
    end

    assert_predicate result, :completed?
    assert_equal [{ "revision" => revision }], seen_ui, "the host never got the ui payload"
    refute Integration.saw?(result.text, revision),
           "the model mentioned a value it should never have seen"
  end

  Integration.scenario(self, :tool_failure_round_trips_as_data) do |model|
    code = Integration.codename
    diagnose = Mistri::Tool.define("diagnose_service", "Runs one service diagnostic.") do
      Mistri::ToolResult.new(
        content: "The diagnostic failed permanently with code #{code}. Do not retry it.",
        error: true
      )
    end
    failures = []
    agent = Mistri::Agent.new(
      provider: Mistri.provider(model), tools: [diagnose],
      system: "Call diagnose_service exactly once. Then report its failure code and stop."
    )

    result = agent.run("Diagnose the service.") do |event|
      failures << event.tool_error if event.type == :tool_result
    end

    refute_empty failures, "the live tool was never called"
    assert_predicate failures, :all?, "the live lifecycle lost its error fact"
    assert Integration.saw?(result.text, code), "the failed result never replayed: #{result.text}"
  end
end
