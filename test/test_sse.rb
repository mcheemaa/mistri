# frozen_string_literal: true

require_relative "test_helper"

class TestSSE < Minitest::Test
  def test_reassembles_records_across_arbitrary_fragment_boundaries
    sse = Mistri::SSE.new
    records = []

    fragments = ["data: {\"a\"", ": 1}\n\nda", "ta: {\"b\": 2}\n"]
    fragments.each { |f| sse.feed(f) { |r| records << r } }

    assert_equal [{ "a" => 1 }, { "b" => 2 }], records
  end

  def test_ignores_event_lines_comments_and_the_done_sentinel
    sse = Mistri::SSE.new
    records = []

    sse.feed("event: message_stop\r\n: keepalive\r\nid: 7\r\ndata: [DONE]\r\n" \
             "data: not json\r\ndata: {\"ok\": true}\r\n") { |r| records << r }

    assert_equal [{ "ok" => true }], records
  end

  def test_finish_flushes_a_record_missing_its_final_newline
    sse = Mistri::SSE.new
    records = []

    sse.feed("data: {\"tail\": true}") { |r| records << r }
    sse.finish { |r| records << r }

    assert_equal [{ "tail" => true }], records
  end

  def test_accepts_a_line_at_the_byte_limit_and_rejects_one_byte_more
    line = "data: {\"ok\":true}"
    records = []
    sse = Mistri::SSE.new(max_record_bytes: line.bytesize)

    sse.feed("#{line}\n") { |record| records << record }

    assert_equal [{ "ok" => true }], records

    error = assert_raises(Mistri::ResponseTooLargeError) do
      Mistri::SSE.new(max_record_bytes: line.bytesize - 1).feed("#{line}\n") { flunk }
    end
    assert_equal :sse_line, error.kind
    assert_equal line.bytesize - 1, error.limit
  end

  def test_counts_fragmented_multibyte_lines_in_bytes
    sse = Mistri::SSE.new(max_record_bytes: 10)

    sse.feed("data: ")
    sse.feed("éé")

    assert_raises(Mistri::ResponseTooLargeError) { sse.feed("x") }
  end

  def test_finds_multiple_lines_by_byte_offset_in_a_utf8_fragment
    sse = Mistri::SSE.new(max_record_bytes: 64)
    records = []

    sse.feed("data: {\"text\":\"é\"}\ndata: {\"text\":\"漢\"}\n") do |record|
      records << record
    end

    assert_equal [{ "text" => "é" }, { "text" => "漢" }], records
  end

  def test_does_not_apply_the_record_limit_to_the_whole_stream
    line = "data: {\"ok\":true}"
    records = []
    sse = Mistri::SSE.new(max_record_bytes: line.bytesize)

    100.times { sse.feed("#{line}\n\n") { |record| records << record } }

    assert_equal 100, records.length
  end

  def test_rejects_invalid_record_limits
    [nil, 0, -1, 1.5, "10"].each do |value|
      error = assert_raises(Mistri::ConfigurationError) do
        Mistri::SSE.new(max_record_bytes: value)
      end

      assert_equal "max_record_bytes: must be a positive integer", error.message
    end
  end
end
