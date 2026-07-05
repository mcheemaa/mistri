# frozen_string_literal: true

require_relative "../support/integration"

# Task mode end to end: validated output with and without tools, on every
# provider including the Gemini validate-and-fix fallback.
class TestStructuredOutputIntegration < Minitest::Test
  SCHEMA = { type: "object",
             properties: { "project" => { type: "string" },
                           "launch_year" => { type: "integer" } },
             required: %w[project launch_year] }.freeze

  Integration.scenario(self, :task_extracts_into_the_schema) do |model|
    project = Integration.codename
    agent = Mistri::Agent.new(provider: Mistri.provider(model))

    result = agent.task("The project #{project} launches in 2031. Extract the details.",
                        schema: SCHEMA)

    assert_empty Mistri::Schema.violations(result.output, SCHEMA)
    assert Integration.saw?(result.output["project"], project)
    assert_equal 2031, result.output["launch_year"]
  end

  Integration.scenario(self, :task_with_tools_reports_the_tools_number) do |model|
    degrees = rand(20..44) + 0.5
    thermo = Mistri::Tool.define("read_thermometer", "The current temperature.") do
      "#{degrees} degrees celsius"
    end
    schema = { type: "object",
               properties: { "temperature_c" => { type: "number" },
                             "summary" => { type: "string" } },
               required: %w[temperature_c summary] }
    agent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [thermo])

    result = agent.task("Use the thermometer and report the reading.", schema: schema)

    assert_empty Mistri::Schema.violations(result.output, schema)
    assert_equal degrees, result.output["temperature_c"],
                 "the answer must carry the tool's exact reading"
  end
end
