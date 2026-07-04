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
end
