# frozen_string_literal: true

require_relative "test_helper"

class TestFakeProvider < Minitest::Test
  def test_a_text_turn_streams_and_assembles
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Hello from Mistri" }])
    events = []

    message = provider.stream { |event| events << event }

    assert_well_formed events
    assert_equal "Hello from Mistri", deltas(events, :text_delta).join
    assert_equal "Hello from Mistri", message.text
    assert_equal :stop, message.stop_reason
    assert_equal message, events.last.message
  end

  def test_a_tool_call_turn_stops_for_tool_use
    turn = { thinking: "Need data.",
             tool_calls: [{ name: "search", arguments: { "q" => "ruby" } }] }
    provider = Mistri::Providers::Fake.new(turns: [turn])
    events = []

    message = provider.stream(messages: [Mistri::Message.user("find ruby")]) { |e| events << e }

    assert_well_formed events
    assert_equal :tool_use, message.stop_reason
    assert_equal "search", message.tool_calls.first.name
    assert_equal({ "q" => "ruby" }, events.find { |e| e.type == :toolcall_end }.tool_call.arguments)
    assert_equal "find ruby", provider.requests.first[:messages].first.text
  end

  def test_an_error_turn_ends_in_band
    provider = Mistri::Providers::Fake.new(turns: [{ error: "overloaded" }])
    events = []

    message = provider.stream { |event| events << event }

    assert_predicate events.last, :error?
    assert_equal :error, message.stop_reason
    assert_equal "overloaded", message.error_message
  end

  def test_partial_snapshots_are_independent
    provider = Mistri::Providers::Fake.new(turns: [{ text: "abcdefghij" }], chunk_size: 3)
    partials = []

    provider.stream { |event| partials << event.partial if event.type == :text_delta }

    assert_equal %w[abc abcdef abcdefghi abcdefghij], partials.map(&:text)
  end

  def test_running_out_of_turns_raises
    assert_raises(Mistri::ConfigurationError) { Mistri::Providers::Fake.new.stream }
  end

  def test_requests_snapshot_the_conversation_at_call_time
    provider = Mistri::Providers::Fake.new(turns: [{ text: "hi" }])
    messages = [Mistri::Message.user("first")]

    messages << provider.stream(messages:)

    assert_equal 1, provider.requests.first[:messages].length
  end

  def test_tool_call_arguments_stream_in_chunks_with_readable_partials
    html = "<main>Hello, page</main>"
    turn = { tool_calls: [{ name: "write_page", arguments: { "html" => html } }] }
    provider = Mistri::Providers::Fake.new(turns: [turn], chunk_size: 8)
    events = []

    provider.stream { |event| events << event }

    assert_well_formed events
    chunks = deltas(events, :toolcall_delta)

    assert_operator chunks.length, :>, 1, "arguments arrive over many deltas"
    assert_equal JSON.generate({ "html" => html }), chunks.join

    calls = events.select { |e| e.type == :toolcall_delta }
                  .map { |e| e.partial.content.last }

    calls.each { |call| assert_equal "write_page", call.name }
    htmls = calls.map { |call| call.arguments["html"].to_s }

    assert_equal htmls.sort_by(&:length), htmls,
                 "the in-progress html only ever grows: #{htmls.inspect}"
    assert_equal html, htmls.last, "the final delta's partial already reads complete"
  end

  private

  def deltas(events, type)
    events.select { |e| e.type == type }.map(&:delta)
  end

  # A stream is one :start, matched start/end pairs per block, one terminal.
  def assert_well_formed(events)
    assert_equal :start, events.first.type
    assert_predicate events.last, :terminal?
    assert_equal 1, events.count(&:terminal?)
    %w[text thinking toolcall].each do |kind|
      starts = events.select { |e| e.type == :"#{kind}_start" }.map(&:content_index)
      ends = events.select { |e| e.type == :"#{kind}_end" }.map(&:content_index)

      assert_equal starts, ends
    end
  end
end
