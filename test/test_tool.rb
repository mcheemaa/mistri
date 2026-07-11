# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestTool < Minitest::Test # rubocop:disable Metrics/ClassLength -- one public tool contract
  def test_argument_violations_report_numeric_resource_limits_honestly
    arguments = Mistri.const_get(:ToolArguments, false)
    huge_integer = 1 << ((arguments::MAX_NUMBER_BYTES + 1) * 4)
    tool = Mistri::Tool.define("measure", "Measures.", schema: lambda {
      integer :value, "Value", required: true
    }) { "ok" }

    assert_equal ["$ validation limit exceeded"],
                 tool.argument_violations({ "value" => huge_integer })
  end

  def test_empty_schema_is_deeply_frozen
    assert_predicate Mistri::Tool::EMPTY_SCHEMA, :frozen?
    assert_predicate Mistri::Tool::EMPTY_SCHEMA.fetch(:properties), :frozen?
    assert_predicate Mistri::Tool::EMPTY_SCHEMA.fetch(:required), :frozen?
    refute Mistri::Tool::EMPTY_SCHEMA.fetch(:additionalProperties)
  end

  def test_a_raw_json_schema_becomes_provider_equivalent_json
    raw = { type: :object, properties: { x: { type: :string } } }
    tool = Mistri::Tool.define("echo", "Echoes.", input_schema: raw) { |args| args["x"] }

    assert_equal({ "type" => "object",
                   "properties" => { "x" => { "type" => "string" } } },
                 tool.spec[:input_schema])
    assert_equal "hi", tool.call({ "x" => "hi" })
  end

  def test_a_tool_owns_one_immutable_provider_and_validation_schema
    raw = { type: "object", properties: { value: { type: "string" } } }
    tool = Mistri::Tool.define("echo", "Echoes.", input_schema: raw) { "ok" }

    raw[:properties][:value][:type] = "number"

    assert_equal "string", tool.input_schema.dig("properties", "value", "type")
    assert_predicate tool.input_schema, :frozen?
    assert_predicate tool.input_schema.dig("properties", "value"), :frozen?
    assert_empty tool.argument_violations("value" => "text")
  end

  def test_raw_and_built_schemas_are_mutually_exclusive
    error = assert_raises(ArgumentError) do
      Mistri::Tool.define(
        "ambiguous", "Ambiguous.", input_schema: { type: "object" }, schema: -> {}
      ) { "ran" }
    end

    assert_equal "choose input_schema or schema, not both", error.message
  end

  def test_false_input_schema_never_becomes_an_open_default
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Tool.define("never", "Accepts nothing.", input_schema: false) { "ran" }
    end

    assert_equal "$ must declare type object for tool arguments", error.message
  end

  def test_complete_validation_authority_is_explicit
    schema = {
      type: "object",
      patternProperties: { "^x-" => { type: "integer" } },
      additionalProperties: false
    }
    supplemental = ->(*) { [] }

    assert_raises(Mistri::ConfigurationError) do
      Mistri::Tool.define("plain", "Plain.", input_schema: schema) { "ran" }
    end
    assert_raises(Mistri::ConfigurationError) do
      Mistri::Tool.define(
        "supplemental", "Supplemental.", input_schema: schema,
                                         argument_validator: supplemental
      ) { "ran" }
    end

    checked = []
    tool = Mistri::Tool.define(
      "complete", "Complete.",
      input_schema: schema,
      complete_argument_validator: lambda { |arguments, owned_schema|
        checked << [arguments, owned_schema]
        arguments.key?("x-count") ? [] : ["$.x-count is required by the host validator"]
      }
    ) { "ran" }

    assert_empty tool.argument_violations("x-count" => 1)
    assert_equal ["$.x-count is required by the host validator"], tool.argument_violations({})
    assert_same tool.input_schema, checked.first.last
  end

  def test_public_argument_validation_gives_custom_rules_the_owned_core_value
    observed = nil
    tool = Mistri::Tool.define(
      "inspect", "Inspects.",
      input_schema: {
        type: "object", properties: { value: { type: "integer" } },
        required: ["value"], additionalProperties: false
      },
      argument_validator: lambda { |arguments, _schema|
        observed = arguments
        []
      }
    ) { "done" }

    assert_empty tool.argument_violations(value: 1)
    assert_equal({ "value" => 1 }, observed)
    assert_predicate observed, :frozen?
    assert_raises(FrozenError) { observed["value"] = 2 }
  end

  def test_tuple_items_use_json_schema_2020_12_prefix_items
    legacy = {
      type: "object",
      properties: {
        "pair" => { type: "array", items: [{ type: "string" }, { type: "integer" }] }
      },
      required: ["pair"]
    }

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::Tool.define("legacy_tuple", "Legacy tuple.", input_schema: legacy) { "ran" }
    end
    assert_equal "$.properties.pair.items must be a schema in JSON Schema 2020-12; " \
                 "use prefixItems for tuples",
                 error.message

    assert_raises(Mistri::ConfigurationError) do
      Mistri::Tool.define(
        "legacy_complete", "Legacy tuple.",
        input_schema: legacy, complete_argument_validator: ->(*) { [] }
      ) { "ran" }
    end

    schema = {
      type: "object",
      properties: {
        "pair" => {
          type: "array", prefixItems: [{ type: "string" }, { type: "integer" }], items: false
        }
      },
      required: ["pair"]
    }
    tool = Mistri::Tool.define("tuple", "Tuple.", input_schema: schema) { "ran" }

    assert_empty tool.argument_violations("pair" => ["sku", 2])
    assert_includes tool.argument_violations("pair" => [2, "sku"]),
                    "$.pair[0] must be string, got integer"
    assert_includes tool.argument_violations("pair" => ["sku", 2, true]),
                    "$.pair[2] is not allowed"
  end

  def test_supplemental_and_complete_validators_are_mutually_exclusive
    error = assert_raises(ArgumentError) do
      Mistri::Tool.define(
        "ambiguous", "Ambiguous.",
        argument_validator: ->(*) { [] },
        complete_argument_validator: ->(*) { [] }
      ) do
        "ran"
      end
    end

    assert_match(/choose argument_validator or complete_argument_validator/, error.message)
  end

  def test_argument_hooks_must_be_callable
    %i[argument_normalizer argument_validator complete_argument_validator].each do |option|
      error = assert_raises(ArgumentError) do
        Mistri::Tool.define("invalid_#{option}", "Invalid hook.", option => true) { "ran" }
      end

      assert_equal "#{option} must be callable", error.message
    end
  end

  def test_custom_argument_validators_must_return_arrays_of_strings
    validators = {
      argument_validator: ->(*) {},
      complete_argument_validator: ->(*) { [1] }
    }

    validators.each do |option, validator|
      tool = Mistri::Tool.define("invalid_#{option}", "Invalid validator.",
                                 option => validator) { "ran" }

      error = assert_raises(TypeError) { tool.argument_violations({}) }

      assert_equal "#{option} must return an Array of Strings", error.message
    end
  end

  def test_the_schema_block_builds_provider_ready_json_schema
    tool = Mistri::Tool.define("get_weather", "Weather for a city.", schema: lambda {
      string :city, "City name", required: true
      string :units, "Units", enum: %w[celsius fahrenheit]
      integer :days, "Forecast length"
      array :alerts, "Alert codes", items: { type: "string" }, required: true, minItems: 1
    }) { |args| args["city"] }

    schema = tool.spec[:input_schema]

    assert_equal "object", schema["type"]
    assert_equal %w[city units days alerts], schema["properties"].keys
    assert_equal %w[celsius fahrenheit], schema["properties"]["units"]["enum"]
    assert_equal({ "type" => "array", "items" => { "type" => "string" },
                   "description" => "Alert codes", "minItems" => 1 },
                 schema["properties"]["alerts"])
    assert_equal %w[city alerts], schema["required"]
  end

  def test_a_blockless_nested_object_is_freeform
    tool = Mistri::Tool.define("render_chart", "Renders a chart.", schema: lambda {
      object :config, "Provider-neutral chart configuration", required: true
      string :title, "Chart title"
    }) { |args| args["config"] }

    schema = tool.spec[:input_schema]
    config = schema["properties"]["config"]

    assert_equal({ "type" => "object", "properties" => {},
                   "description" => "Provider-neutral chart configuration" }, config)
    assert_equal ["config"], schema["required"]
    assert_equal "string", schema.dig("properties", "title", "type")
    assert_empty Mistri::Schema.violations(
      { "config" => { "series" => [{ "type" => "bar", "data" => [1, 2] }] } },
      schema
    )
    assert_equal ["$.config must be object, got string"],
                 Mistri::Schema.violations({ "config" => "bar" }, schema)
  end

  def test_a_nested_object_block_keeps_its_declared_shape
    tool = Mistri::Tool.define("locate", "Locates a place.", schema: lambda {
      object :location, "Place to locate", required: true do
        string :city, "City name", required: true
        string :country, "Country code"
      end
    }) { |args| args["location"] }

    assert_equal(
      {
        "type" => "object",
        "properties" => {
          "city" => { "type" => "string", "description" => "City name" },
          "country" => { "type" => "string", "description" => "Country code" }
        },
        "required" => ["city"],
        "description" => "Place to locate"
      },
      tool.spec[:input_schema]["properties"]["location"]
    )
  end

  def test_schema_build_requires_a_root_block
    error = assert_raises(Mistri::ConfigurationError) { Mistri::Schema.build }

    assert_equal "schema needs a block", error.message
  end

  def test_schema_build_accepts_an_explicit_empty_block
    assert_equal({ type: "object", properties: {} }, Mistri::Schema.build { nil })
  end

  def test_results_serialize_by_type
    string_tool = Mistri::Tool.define("s", "d") { "text" }
    hash_tool = Mistri::Tool.define("h", "d") { { ok: true } }
    nil_tool = Mistri::Tool.define("n", "d") { nil }
    image_tool = Mistri::Tool.define("i", "d") do
      Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
    end

    assert_equal "text", string_tool.call({})
    assert_equal({ "ok" => true }, JSON.parse(hash_tool.call({})))
    assert_equal "", nil_tool.call({})
    assert_instance_of Mistri::Content::Image, image_tool.call({})
  end

  def test_an_array_of_data_returns_as_json_not_inspect_output
    rows_tool = Mistri::Tool.define("rows", "d") { [{ "sku" => "A1" }, { "sku" => "B2" }] }

    assert_equal [{ "sku" => "A1" }, { "sku" => "B2" }], JSON.parse(rows_tool.call({}))

    blocks_tool = Mistri::Tool.define("blocks", "d") do
      [Mistri::Content::Image.from_bytes("x", mime_type: "image/png"), "caption"]
    end
    result = blocks_tool.call({})

    assert_kind_of Array, result
    assert_instance_of Mistri::Content::Image, result.first
  end

  def test_a_tool_without_a_handler_is_rejected
    assert_raises(ArgumentError) { Mistri::Tool.define("bad", "no block") }
  end

  def test_a_no_argument_tool_gets_a_valid_object_schema
    tool = Mistri::Tool.define("now", "Current time.") { Time.now.to_s }

    assert_equal({ "type" => "object", "properties" => {}, "required" => [],
                   "additionalProperties" => false }, tool.spec[:input_schema])
  end

  def test_eager_streaming_shows_up_in_the_spec
    tool = Mistri::Tool.define("write", "Writes.", eager_input_streaming: true) { "ok" }

    assert tool.spec[:eager_input_streaming]
  end

  def test_a_timeout_answers_in_band_instead_of_stalling_the_run
    slow = Mistri::Tool.define("slow", "Sleeps.", timeout: 0.1) do
      sleep 1
      "never"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "slow", arguments: {} }] },
                                             { text: "moving on" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [slow])

    result = agent.run("go")

    assert_predicate result, :completed?
    answer = agent.session.messages.select(&:tool?).last

    assert_match(/timed out after 0.1s/, answer.text)
    assert_predicate answer, :tool_error?
  end

  def test_a_handler_timeout_error_is_not_mislabeled_as_the_configured_timeout
    tool = Mistri::Tool.define("upstream", "Calls upstream.", timeout: 1) do
      raise Timeout::Error, "upstream timed out"
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "upstream",
                                                              arguments: {} }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool])

    agent.run("go")

    answer = agent.session.messages.select(&:tool?).last

    assert_includes answer.text, "Timeout::Error: upstream timed out"
    refute_includes answer.text, "timed out after 1s"
    assert_predicate answer, :tool_error?
  end

  def test_abort_at_the_serialized_start_boundary_never_announces_the_next_call
    signal = Mistri::AbortSignal.new
    resolved = Queue.new
    ran = []
    definitions = %w[a b].to_h do |name|
      tool = Mistri::Tool.define(name, "Runs.") do
        ran << name
        name
      end
      [name, tool]
    end
    lookup = Object.new
    lookup.define_singleton_method(:[]) do |name|
      resolved << name
      definitions[name]
    end
    calls = %w[a b].map { |name| Mistri::ToolCall.new(id: name, name:, arguments: {}) }
    started = []
    emit = lambda do |event|
      next unless event.type == :tool_started

      2.times { resolved.pop } if started.empty?
      started << event.tool_call.name
      signal.abort!(:test) if started.length == 1
    end

    results = Mistri::ToolExecutor.call(calls, lookup, signal:, max_concurrency: 2, emit:)

    assert_equal 1, started.length
    assert_equal started, ran
    interrupted = results.find { |call, _result, _duration| call.name != started.first }

    assert_predicate interrupted[1], :error?
    assert_equal Mistri::ToolExecutor::INTERRUPTED, interrupted[1].content
    assert_nil interrupted[2]
  end

  def test_tool_results_carry_their_duration
    quick = Mistri::Tool.define("quick", "Q.") { "ok" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "quick", arguments: {} }] },
                                             { text: "done" }
                                           ])
    durations = []
    Mistri::Agent.new(provider:, tools: [quick]).run("go") do |event|
      durations << event.duration if event.type == :tool_result
    end

    assert_equal 1, durations.length
    assert_operator durations.first, :>=, 0.0
    assert_kind_of Float, durations.first
  end
end # rubocop:enable Metrics/ClassLength
