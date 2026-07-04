# frozen_string_literal: true

require "json"
require_relative "test_helper"

class TestPartialJson < Minitest::Test
  GNARLY = [
    '{"name":"mistri","tags":["agent","ruby"],"nested":{"depth":2,"ok":true}}',
    <<~'JSON'.strip,
      {"text":"line\nquote\"backslash\\unicode❤emoji🔥","empty":""}
    JSON
    '{"ints":[0,-7,42],"floats":[1.5,-0.25,6.02e23,1e-9],"none":null,"flags":[true,false]}',
    '[[],{},[[1]],{"a":{}}]',
    '"top-level string with é"',
    "-12.5e-3"
  ].freeze

  def test_every_prefix_parses_and_converges_to_the_full_document
    GNARLY.each do |doc|
      (1...doc.length).each { |len| Mistri::PartialJson.parse(doc[0, len]) }

      assert_equal JSON.parse(doc), Mistri::PartialJson.parse(doc)
    end
  end

  def test_a_string_cut_mid_value_returns_the_text_so_far
    assert_equal({ "query" => "he" }, Mistri::PartialJson.parse('{"query": "he'))
  end

  def test_a_dangling_key_is_dropped_whole
    ['{"a": 1, "b', '{"a": 1, "b"', '{"a": 1, "b":'].each do |prefix|
      assert_equal({ "a" => 1 }, Mistri::PartialJson.parse(prefix))
    end
  end

  def test_truncated_literals_and_numbers_complete
    assert_equal({ "t" => true }, Mistri::PartialJson.parse('{"t": tru'))
    assert_equal({ "z" => nil }, Mistri::PartialJson.parse('{"z": nul'))
    assert_equal({ "e" => 1.5 }, Mistri::PartialJson.parse('{"e": 1.5e'))
    assert_empty Mistri::PartialJson.parse('{"n": -')
  end

  def test_half_written_escapes_are_shed
    assert_equal({ "s" => "a" }, Mistri::PartialJson.parse('{"s": "a\\'))
    assert_equal({ "u" => "" }, Mistri::PartialJson.parse('{"u": "\u26'))
  end

  def test_nested_structures_keep_their_shape_mid_stream
    assert_equal [1, 2, { "x" => [3] }], Mistri::PartialJson.parse('[1, 2, {"x": [3')
  end

  def test_overflow_and_infinity_never_raise_or_poison_json
    deep = Mistri::PartialJson.parse("[" * 10_000)

    assert_kind_of Array, deep
    infinite = Mistri::PartialJson.parse('{"x": 1e999}')

    assert_empty infinite
    assert(JSON.generate(Mistri::PartialJson.parse('{"y": 1e999, "z": 2}')))
  end

  def test_a_complete_trailing_backslash_survives_mid_stream_salvage
    assert_equal({ "s" => "a\\" }, Mistri::PartialJson.parse('{"s": "a\\\\'))
  end

  def test_hopeless_input_returns_an_empty_hash
    ["", "   ", "garbage", "[}"].each do |input|
      result = Mistri::PartialJson.parse(input)

      assert_includes [{}, []], result,
                      "expected empty for #{input.inspect}, got #{result.inspect}"
    end
  end
end
