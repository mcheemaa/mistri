# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/live_report"
require_relative "support/stub_server"

class TestLiveReport < Minitest::Test
  MESSAGES = [Mistri::Message.user("hi")].freeze

  def setup
    @report = Mistri::Test::LiveReport.new
    @server = Mistri::Test::StubServer.new { |socket, _request| answer(socket) }
  end

  def teardown
    @server.stop
  end

  def test_a_call_to_the_vendor_is_recorded_with_its_model_and_usage
    provider = vendor(origin: "#{@server.origin}/", model: "claude-haiku-5-5")

    provider.stream(messages: MESSAGES)
    provider.stream(messages: MESSAGES, model: "claude-opus-5-5")

    calls = @report.calls

    assert_equal %w[claude-haiku-5-5 claude-opus-5-5], calls.map(&:model)
    assert_equal [1_200, 340], [calls.first.usage.input, calls.first.usage.output]
    assert(calls.all? { |call| call.seconds.positive? })
  ensure
    provider&.close
  end

  def test_a_call_to_another_origin_is_not_recorded
    provider = recorded(Mistri::Providers::Anthropic::DEFAULT_ORIGIN)
               .new(api_key: "test", origin: @server.origin)

    assert_predicate provider.stream(messages: MESSAGES), :assistant?
    assert_empty @report.calls
  ensure
    provider&.close
  end

  def test_the_summary_prices_each_model_from_the_catalog
    provider = vendor(model: "claude-haiku-5-5", catalog_pricing: true)
    2.times { provider.stream(messages: MESSAGES) }
    provider.stream(messages: MESSAGES, model: "claude-opus-5-5")

    summary = @report.summary([])
    haiku = cost("claude-haiku-5-5", calls: 2)
    opus = cost("claude-opus-5-5", calls: 1)

    assert_match(/claude-haiku-5-5 +2 +\d+\.\d +2,400 +0 +0 +680 +#{dollars(haiku)}$/, summary)
    assert_match(/claude-opus-5-5 +1 +\d+\.\d +1,200 +0 +0 +340 +#{dollars(opus)}$/, summary)
    assert_match(/total +3 +\d+\.\d +3,600 +0 +0 +1,020 +#{dollars(haiku + opus)}$/, summary)
    assert_operator summary.index("claude-opus-5-5"), :<, summary.index("claude-haiku-5-5")
    refute_includes summary, "had no price"
  ensure
    provider&.close
  end

  def test_the_summary_says_when_a_call_had_no_price
    provider = vendor(model: "claude-haiku-5-5")
    provider.stream(messages: MESSAGES)

    assert_includes @report.summary([]),
                    "1 of these calls had no price. The dollars leave them out."
  ensure
    provider&.close
  end

  def test_the_summary_lists_the_slowest_tests_first
    provider = vendor
    provider.stream(messages: MESSAGES)
    tests = (1..12).map { |number| [number.to_f, "TestThing#test_#{number}"] }

    lines = @report.summary(tests).lines.map(&:strip)
    slowest = lines.drop_while { |line| line != "Slowest tests" }

    assert_equal "12.0 s  TestThing#test_12", slowest[1]
    assert_equal "3.0 s  TestThing#test_3", slowest.last
    assert_equal 11, slowest.length
  ensure
    provider&.close
  end

  private

  # A provider for which the stub server is the vendor.
  def vendor(origin: @server.origin, **)
    recorded(@server.origin).new(api_key: "test", origin:, **)
  end

  def recorded(vendor)
    Class.new(Mistri::Providers::Anthropic).tap do |provider|
      provider.prepend(@report.recorder(vendor))
    end
  end

  def cost(model, calls:)
    usage = Mistri::Usage.new(input: 1_200 * calls, output: 340 * calls)
    usage.with_cost(Mistri::Models.rates(model)).cost.total
  end

  def dollars(amount) = Regexp.escape(format("%.4f", amount))

  def answer(socket)
    @server.start_sse(socket)
    @server.sse_data(socket, { "type" => "message_start",
                               "message" => { "usage" => { "input_tokens" => 1_200,
                                                           "service_tier" => "standard" } } })
    @server.sse_data(socket, { "type" => "message_delta",
                               "delta" => { "stop_reason" => "end_turn" },
                               "usage" => { "output_tokens" => 340 } })
    @server.sse_data(socket, { "type" => "message_stop" })
    @server.finish_sse(socket)
  end
end
