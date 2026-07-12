# frozen_string_literal: true

require_relative "../support/integration"

# The loop end to end: generated facts must travel through tool results into
# the answer, and the ui side-channel must reach the host and never the model.
class TestCoreLoopIntegration < Minitest::Test
  Integration.scenario(self, :tools_carry_generated_facts) do |model|
    founder = Integration.marker
    city = Integration.marker
    founder_tool = Mistri::Tool.define(
      "founder_name", "Returns the exact FOUNDER_NAME value."
    ) { "FOUNDER_NAME=#{founder}" }
    hq_tool = Mistri::Tool.define(
      "hq_city", "Returns the exact HQ_CITY value."
    ) { "HQ_CITY=#{city}" }
    agent = Mistri::Agent.new(provider: Mistri.provider(model),
                              tools: [founder_tool, hq_tool],
                              system: "Call both tools. Answer only from their labeled values, " \
                                      "copying each value exactly without changing its spelling.")
    events = []

    result = agent.run("Who founded the company and what city is HQ in? One sentence.") do |event|
      events << event
    end

    assert_predicate result, :completed?
    assert_equal :start, events.first.type, "the provider stream did not open with :start"
    assert_predicate events.first.partial, :assistant?
    assert_empty events.first.partial.content
    assert_stream_boundaries(events)
    assert_predicate events.last, :terminal?
    assert Integration.carried?(result.text, founder), "founder fact never flowed: #{result.text}"
    assert Integration.carried?(result.text, city), "city fact never flowed: #{result.text}"
  end

  def assert_stream_boundaries(events)
    open = false
    events.each do |event|
      if event.type == :start
        refute open, "a provider stream opened before its predecessor terminated"
        open = true
      elsif event.terminal?
        assert open, "a provider terminal arrived without a matching :start"
        open = false
      end
    end

    refute open, "the final provider stream never terminated"
  end

  # Serializer tests prove ui never reaches provider input; this live path
  # proves host delivery and keeps the final response as a leakage canary.
  Integration.scenario(self, :ui_channel_reaches_host) do |model|
    revision = Integration.marker
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
    code = Integration.marker
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

    assert_predicate result, :completed?
    refute_empty failures, "the live tool was never called"
    assert_predicate failures, :all?, "the live lifecycle lost its error fact"
    assert Integration.carried?(result.text, code),
           "the failed result never replayed: #{result.text}"
  end

  Integration.scenario(self, :invalid_tool_arguments_are_corrected_before_execution) do |model|
    correction = Integration.marker
    validated = []
    handled = []
    submit = Mistri::Tool.define(
      "submit_code", "Submits one validation code.",
      schema: -> { string :code, "Validation code", required: true },
      argument_validator: lambda do |args, _schema|
        validated << args.fetch("code")
        args["code"] == correction ? [] : ["$.code must be exactly #{correction}"]
      end
    ) do |args|
      handled << args.fetch("code")
      "Accepted #{args.fetch("code")}."
    end
    errors = []
    calls = []
    agent = Mistri::Agent.new(
      provider: Mistri.provider(model), tools: [submit],
      budget: Mistri::Budget.new(turns: 8),
      system: "First call submit_code with code exactly wrong. When it returns an argument " \
              "error, call it once more with the exact correction it gives you, then report " \
              "the accepted code."
    )

    result = agent.run("Exercise the validation correction path.") do |event|
      errors << event.tool_error if event.type == :tool_result
      calls << event.tool_call if event.type == :toolcall_end
    end

    assert_predicate result, :completed?
    assert_operator validated.length, :>=, 2, "the model never exercised the rejected path"
    refute_equal correction, validated.first, "the first call skipped validation correction"
    refute_empty handled, "the corrected call never reached the handler"
    assert_equal [correction], handled.uniq, "invalid arguments reached the handler"
    assert errors.first, "the rejection lost its error type"
    refute errors.last, "the accepted call stayed mislabeled as an error"
    assert_equal handled.length, errors.count(false), "a valid handler outcome was mislabeled"
    assert Integration.carried?(result.text, correction), "the corrected result never landed"
    if model.start_with?("gemini-3")
      ids = calls.map(&:provider_call_id)

      assert ids.all? { |id| id.is_a?(String) && !id.empty? },
             "Gemini 3 function-call IDs were not preserved"
      assert_equal ids.uniq, ids, "Gemini 3 reused a provider function-call ID"
    end
  end
end
