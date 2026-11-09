# frozen_string_literal: true

require "json"
require "logger"
require "stringio"
require_relative "test_helper"
require_relative "support/stub_server"

# A changed prefix must cost stale thinking, never the session.
class TestAnthropicThinkingBinding < Minitest::Test
  HISTORY = [Mistri::Message.user("hello")].freeze
  DROP = { prefix_mismatch_behavior: "drop_block" }.freeze
  BETA = "thinking-binding-controls-2026-08-01"

  def teardown
    @provider&.close
    @server&.stop
  end

  def test_adaptive_thinking_on_the_official_origin_drops_stale_blocks
    @provider = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-5-5")

    body = body_for("claude-opus-5-5")

    assert_equal({ type: "adaptive", display: "summarized", block_binding: DROP }, body[:thinking])
    assert_equal BETA, @provider.send(:headers, body)["anthropic-beta"]
  end

  def test_a_request_without_adaptive_thinking_carries_no_control
    @provider = Mistri::Providers::Anthropic.new(api_key: "k", model: "claude-opus-5-5")
    budget = { type: "enabled", budget_tokens: 2_000 }

    bodies = [body_for("claude-opus-5-5", thinking: nil), body_for("claude-haiku-4-5"),
              body_for("claude-haiku-4-5", thinking: budget)]

    assert_equal([nil, nil, budget], bodies.map { |body| body[:thinking] })
    bodies.each { |body| refute @provider.send(:headers, body).key?("anthropic-beta") }
  end

  def test_a_custom_origin_sends_the_control_only_when_the_host_asks
    @server = Mistri::Test::StubServer.new do |socket, _request|
      @server.start_sse(socket)
      @server.sse_data(socket, { "type" => "message_stop" })
      @server.finish_sse(socket)
    end
    strict = { type: "adaptive", block_binding: { prefix_mismatch_behavior: "error" } }
    @provider = Mistri::Providers::Anthropic.new(api_key: "k", origin: @server.origin)

    @provider.stream(messages: HISTORY)
    @provider.stream(messages: HISTORY, thinking: strict)
    plain, asked = @server.requests

    assert_equal({ "type" => "adaptive", "display" => "summarized" },
                 JSON.parse(plain[:body])["thinking"])
    refute plain[:headers].key?("anthropic-beta")
    assert_equal({ "prefix_mismatch_behavior" => "error" },
                 JSON.parse(asked[:body]).dig("thinking", "block_binding"))
    assert_equal BETA, asked[:headers]["anthropic-beta"]
  end

  def test_the_stream_reports_dropped_thinking_once_per_request
    events = []
    message = assemble([dropped("prefix_binding_mismatch"), dropped("prefix_binding_mismatch"),
                        dropped("model_binding_mismatch")]) { |event| events << event }
    reports = events.select { |event| event.type == :thinking_dropped }

    assert_equal ["prefix_binding_mismatch, model_binding_mismatch"], reports.map(&:content)
    assert_equal :stop, message.stop_reason
    assert_equal "ok", message.text
  end

  def test_an_unchanged_prefix_reports_nothing
    events = []
    assemble([]) { |event| events << event }
    assemble(nil) { |event| events << event }
    assemble([{ "type" => "something_new" }]) { |event| events << event }

    assert_empty(events.select { |event| event.type == :thinking_dropped })
  end

  def test_the_run_log_warns_when_a_changed_prefix_dropped_thinking
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.formatter = ->(severity, _time, _progname, text) { "#{severity} #{text}\n" }
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :thinking_dropped, content: "prefix_binding_mismatch"))
    sink.call(Mistri::Event.new(type: :thinking_dropped, content: "model_binding_mismatch"))

    assert_equal ["WARN [mistri] thinking dropped: prefix_binding_mismatch\n",
                  "WARN [mistri] thinking dropped: model_binding_mismatch\n"], io.string.lines
  end

  private

  def body_for(model, **overrides)
    @provider.send(:build_body, model, HISTORY, nil, [], overrides)
  end

  def dropped(reason)
    { "type" => "thinking_dropped", "path" => "messages.1.content.0", "reason" => reason }
  end

  def assemble(transformations, &)
    assembler = Mistri::Providers::Anthropic::Assembler.new(model: "claude-opus-5-5")
    start = { "usage" => { "input_tokens" => 1 } }
    start["input_transformations"] = transformations unless transformations.nil?
    [{ "type" => "message_start", "message" => start },
     { "type" => "content_block_start", "index" => 0, "content_block" => { "type" => "text" } },
     { "type" => "content_block_delta", "index" => 0,
       "delta" => { "type" => "text_delta", "text" => "ok" } },
     { "type" => "content_block_stop", "index" => 0 },
     { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
       "usage" => { "output_tokens" => 1 } },
     { "type" => "message_stop" }].each { |record| assembler.feed(record, &) }
    assembler.finish(&)
  end
end
