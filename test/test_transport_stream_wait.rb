# frozen_string_literal: true

require "timeout"
require_relative "test_helper"

# How long a stream is read. Near a deadline the socket's own timer and the
# check made when bytes arrive can each end the wait, so the check is tested
# here with chunks that arrive when the test says and no socket at all.
class TestTransportStreamWait < Minitest::Test
  Response = Struct.new(:chunks) do
    def read_body
      chunks.each do |wait, chunk|
        sleep(wait)
        yield chunk
      end
    end
  end
  Connection = Struct.new(:read_timeout)

  def reading(read_timeout, chunks, &)
    transport = Mistri::Transport.new(origin: "http://127.0.0.1:1", read_timeout: read_timeout)
    @connection = Connection.new(read_timeout)
    transport.instance_variable_set(:@connection, @connection)
    transport.send(:read_events, Response.new(chunks), Mistri::SSE.new, &)
  end

  def test_a_stream_that_keeps_sending_after_its_answer_is_left
    seen = []
    chunks = [[0, %(data: {"n":1}\n\n)], [0.15, ": still open\n\n"]]
    ended = catch(:left) do
      reading(5, chunks) { |record| seen << record }
      :read_to_its_end
    end

    assert_nil ended, "the stream was left before its end"
    assert_equal [{ "n" => 1 }], seen
    assert_equal 5, @connection.read_timeout, "the connection has its own timeout again"
  end

  def test_bytes_that_are_no_message_do_not_hold_a_stream_open
    error = assert_raises(Timeout::Error) do
      reading(0.05, [[0, ": one\n\n"], [0.08, ": two\n\n"]]) { flunk "a comment is no record" }
    end

    assert_equal "no message from the server in 0.05 seconds", error.message
  end

  def test_a_stream_with_no_read_timeout_is_read_without_one
    seen = []
    reading(nil, [[0, ": a comment\n\n"], [0, %(data: {"n":1}\n\n)]]) do |record|
      seen << record
      nil
    end

    assert_equal [{ "n" => 1 }], seen
    assert_nil @connection.read_timeout
  end

  def test_a_message_starts_the_wait_again
    seen = []
    reading(0.1, [[0.06, %(data: {"n":1}\n\n)], [0.06, %(data: {"n":2}\n\n)]]) do |record|
      seen << record
      nil
    end

    assert_equal [{ "n" => 1 }, { "n" => 2 }], seen
  end
end
