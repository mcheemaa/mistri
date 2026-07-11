# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Sinks bridge the event stream to a transport: SSE frames, Action Cable
# broadcasts, and a coalescer that merges delta bursts to UI speed.
class TestSinks < Minitest::Test
  def delta(text, index: 0, origin: nil)
    Mistri::Event.new(type: :text_delta, content_index: index, delta: text, origin: origin)
  end

  def test_coalesced_merges_a_burst_into_one_delta
    seen = []
    sink = Mistri::Sinks::Coalesced.new(->(event) { seen << event }, interval: 60)

    ["Hel", "lo", " world"].each { |chunk| sink.call(delta(chunk)) }
    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "Hello world"))

    assert_equal %i[text_delta text_end], seen.map(&:type)
    assert_equal "Hello world", seen.first.delta
  end

  def test_coalesced_flushes_between_content_blocks
    seen = []
    sink = Mistri::Sinks::Coalesced.new(->(event) { seen << event }, interval: 60)

    sink.call(delta("first", index: 0))
    sink.call(delta("second", index: 1))
    sink.call(Mistri::Event.new(type: :done, reason: :stop))

    assert_equal %i[text_delta text_delta done], seen.map(&:type)
    assert_equal %w[first second], seen.first(2).map(&:delta)
    assert_equal [0, 1], seen.first(2).map(&:content_index)
  end

  def test_coalesced_passes_other_events_through_in_order
    seen = []
    sink = Mistri::Sinks::Coalesced.new(->(event) { seen << event }, interval: 60)

    sink.call(Mistri::Event.new(type: :start))
    sink.call(delta("partial answer"))
    call = Mistri::ToolCall.new(id: "c1", name: "run", arguments: {})
    sink.call(Mistri::Event.new(type: :tool_started, tool_call: call))
    sink.call(Mistri::Event.new(type: :tool_result, content: "ran", tool_error: false))

    assert_equal %i[start text_delta tool_started tool_result], seen.map(&:type),
                 "the buffered delta flushes before the next non-delta event"
  end

  def test_coalesced_never_merges_across_origins
    seen = []
    sink = Mistri::Sinks::Coalesced.new(->(event) { seen << event }, interval: 60)

    sink.call(delta("parent says "))
    sink.call(delta("child says ", origin: "Corgi#ab12cd34"))
    sink.call(delta("hello", origin: "Corgi#ab12cd34"))
    sink.call(Mistri::Event.new(type: :done, reason: :stop))

    deltas = seen.select { |event| event.type == :text_delta }

    assert_equal ["parent says ", "child says hello"], deltas.map(&:delta),
                 "a lane keeps its own bytes even at the same content index"
    assert_equal [nil, "Corgi#ab12cd34"], deltas.map(&:origin)
  end

  # A background worker emits from its own thread while the parent streams;
  # the coalescer must serialize them. Exact chunking is timing-dependent,
  # so the assertions are the invariants: every lane's bytes arrive intact,
  # in order, and never inside another lane's event.
  def test_coalesced_is_safe_under_concurrent_emitters
    seen = []
    sink = Mistri::Sinks::Coalesced.new(->(event) { seen << event }, interval: 60)
    lanes = { nil => "the parent narrates its own turn",
              "Corgi#1" => "corgi reports pricing findings",
              "Husky#2" => "husky reports founder findings" }

    lanes.map do |origin, text|
      Thread.new { text.chars.each { |char| sink.call(delta(char, origin: origin)) } }
    end.each(&:join)
    sink.call(Mistri::Event.new(type: :done, reason: :stop))

    lanes.each do |origin, text|
      arrived = seen.select { |e| e.type == :text_delta && e.origin == origin }
                    .map(&:delta).join

      assert_equal text, arrived, "lane #{origin.inspect} lost or mixed bytes"
    end
    assert_equal :done, seen.last.type, "the terminal still flushes and forwards last"
  end

  def test_coalesced_with_zero_interval_flushes_every_delta
    seen = []
    sink = Mistri::Sinks::Coalesced.new(->(event) { seen << event }, interval: 0)

    sink.call(delta("a"))
    sink.call(delta("b"))

    assert_equal %w[a b], seen.map(&:delta)
  end

  def test_sse_writes_one_frame_per_event
    io = StringIO.new
    sink = Mistri::Sinks::SSE.new(io)

    sink.call(delta("hi"))
    sink.call(Mistri::Event.new(type: :done, reason: :stop))

    frames = io.string.split("\n\n").reject(&:empty?)

    assert_equal 2, frames.length
    assert frames.first.start_with?("event: text_delta\ndata: ")
    assert_includes frames.first, '"delta":"hi"'
    assert_includes frames.last, "event: done"
  end

  def test_sse_carries_tool_failure_as_json_data
    io = StringIO.new
    sink = Mistri::Sinks::SSE.new(io)

    sink.call(Mistri::Event.new(type: :tool_result, content: "failed", tool_error: true))

    assert_includes io.string, "event: tool_result"
    assert_includes io.string, '"tool_error":true'
  end

  def test_action_cable_broadcasts_event_hashes_to_the_stream
    broadcasts = []
    server = Object.new
    server.define_singleton_method(:broadcast) { |stream, payload| broadcasts << [stream, payload] }
    sink = Mistri::Sinks::ActionCable.new("agent_9", server: server)

    sink.call(delta("hi"))

    stream, payload = broadcasts.first

    assert_equal "agent_9", stream
    assert_equal :text_delta, payload[:type]
    assert_equal "hi", payload[:delta]
  end

  def test_action_cable_broadcasts_known_success_without_dropping_false
    broadcasts = []
    server = Object.new
    server.define_singleton_method(:broadcast) { |_stream, payload| broadcasts << payload }
    sink = Mistri::Sinks::ActionCable.new("agent_9", server: server)

    sink.call(Mistri::Event.new(type: :tool_result, content: "ok", tool_error: false))

    assert broadcasts.first.key?(:tool_error)
    refute broadcasts.first.fetch(:tool_error)
  end

  def test_sinks_compose_as_blocks
    seen = []
    sink = Mistri::Sinks::Coalesced.new(->(event) { seen << event }, interval: 0)
    provider = Mistri::Providers::Fake.new(turns: [{ text: "streamed" }])

    Mistri::Agent.new(provider:).run("go", &sink)

    assert_includes seen.map(&:type), :text_delta
    assert_equal :done, seen.last.type
  end
end
