# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestTool < Minitest::Test
  def test_a_raw_json_schema_passes_straight_through
    raw = { type: "object", properties: { x: { type: "string" } } }
    tool = Mistri::Tool.define("echo", "Echoes.", input_schema: raw) { |args| args["x"] }

    assert_equal(raw, tool.spec[:input_schema])
    assert_equal "hi", tool.call({ "x" => "hi" })
  end

  def test_the_schema_block_builds_provider_ready_json_schema
    tool = Mistri::Tool.define("get_weather", "Weather for a city.", schema: lambda {
      string :city, "City name", required: true
      string :units, "Units", enum: %w[celsius fahrenheit]
      integer :days, "Forecast length"
    }) { |args| args["city"] }

    schema = tool.spec[:input_schema]

    assert_equal "object", schema[:type]
    assert_equal %w[city units days], schema[:properties].keys
    assert_equal %w[celsius fahrenheit], schema[:properties]["units"][:enum]
    assert_equal ["city"], schema[:required]
  end

  def test_a_blockless_nested_object_is_freeform
    tool = Mistri::Tool.define("render_chart", "Renders a chart.", schema: lambda {
      object :config, "Provider-neutral chart configuration", required: true
      string :title, "Chart title"
    }) { |args| args["config"] }

    schema = tool.spec[:input_schema]
    config = schema[:properties]["config"]

    assert_equal({ type: "object", properties: {},
                   description: "Provider-neutral chart configuration" }, config)
    assert_equal ["config"], schema[:required]
    assert_equal "string", schema.dig(:properties, "title", :type)
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
        type: "object",
        properties: {
          "city" => { type: "string", description: "City name" },
          "country" => { type: "string", description: "Country code" }
        },
        required: ["city"],
        description: "Place to locate"
      },
      tool.spec[:input_schema][:properties]["location"]
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
    image_tool = Mistri::Tool.define("i", "d") do
      Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
    end

    assert_equal "text", string_tool.call({})
    assert_equal({ "ok" => true }, JSON.parse(hash_tool.call({})))
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

    assert_equal({ type: "object", properties: {} }, tool.spec[:input_schema])
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
    assert_match(/timed out after 0.1s/, agent.session.messages.select(&:tool?).last.text)
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
end
