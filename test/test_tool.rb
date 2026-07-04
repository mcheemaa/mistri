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

  def test_a_tool_without_a_handler_is_rejected
    assert_raises(ArgumentError) { Mistri::Tool.define("bad", "no block") }
  end

  def test_eager_streaming_shows_up_in_the_spec
    tool = Mistri::Tool.define("write", "Writes.", eager_input_streaming: true) { "ok" }

    assert tool.spec[:eager_input_streaming]
  end
end
