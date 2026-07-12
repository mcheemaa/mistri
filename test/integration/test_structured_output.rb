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
    project = Integration.marker
    agent = Mistri::Agent.new(provider: Mistri.provider(model))

    result = agent.task("The project #{project} launches in 2031. Extract the details.",
                        schema: SCHEMA)

    assert_empty Mistri::Schema.violations(result.output, SCHEMA)
    assert_equal project, result.output["project"]
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
    calls = []

    result = agent.task("Use the thermometer and report the reading.", schema: schema) do |event|
      calls << event.tool_call.name if event.type == :tool_result
    end

    assert_empty Mistri::Schema.violations(result.output, schema)
    assert_includes calls, "read_thermometer", "the task never called its data source"
    assert_equal degrees, result.output["temperature_c"],
                 "the answer must carry the tool's exact reading"
  end

  Integration.scenario(self, :scalar_and_tuple_tasks_survive_provider_schema_differences) do |model|
    scalar = Integration.marker
    scalar_result = Mistri::Agent.new(provider: Mistri.provider(model)).task(
      "Return the exact JSON string #{scalar.inspect}.",
      schema: { type: "string", enum: [scalar] }
    )

    tuple_value = Integration.marker
    tuple_schema = {
      type: "array",
      prefixItems: [{ type: "string", enum: [tuple_value] },
                    { type: "integer", enum: [37] }],
      items: false
    }
    tuple_result = Mistri::Agent.new(provider: Mistri.provider(model)).task(
      "Return a JSON array containing exactly #{tuple_value.inspect} and 37.",
      schema: tuple_schema
    )

    assert_equal scalar, scalar_result.output
    assert_equal [tuple_value, 37], tuple_result.output
  end
end
