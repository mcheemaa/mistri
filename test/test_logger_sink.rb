# frozen_string_literal: true

require_relative "test_helper"
require "logger"
require "stringio"

# The logging sink renders the event stream as one line per beat, and
# assigning Mistri.logger makes every run log its own story exactly once,
# sub-agents included.
class TestLoggerSink < Minitest::Test
  class Boom < StandardError
  end

  def teardown
    Mistri.logger = nil
  end

  def capture
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.formatter = ->(severity, _time, _progname, message) { "#{severity} #{message}\n" }
    [logger, io]
  end

  def tool_call(name, arguments = {})
    Mistri::ToolCall.new(id: "c1", name: name, arguments: arguments)
  end

  def test_logs_tool_calls_with_arguments_duration_and_verdict
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :tool_started, tool_call: tool_call("add", { "a" => 2 })))
    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("add"),
                                content: "5", duration: 0.012, tool_error: false))

    assert_match(/INFO \[mistri\] tool add \{"a":2\}/, io.string)
    assert_match(/INFO \[mistri\] tool add ok 12ms "5"/, io.string)
  end

  def test_marks_failed_tools_at_warn
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("boom"),
                                content: "kaboom", duration: 2.34, tool_error: true))

    assert_match(/WARN \[mistri\] tool boom FAILED 2.3s "kaboom"/, io.string)
  end

  def test_skips_deltas_and_origin_tagged_events
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :text_delta, content_index: 0, delta: "Hel"))
    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "from a child",
                                origin: "Corgi#ab12cd34"))

    assert_empty io.string
  end

  def test_numbers_turns_and_flags_errors_and_retries
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :done, reason: :tool_use))
    sink.call(Mistri::Event.new(type: :done, reason: :stop))
    sink.call(Mistri::Event.new(type: :retry, content: "rate limited", attempt: 2,
                                max_attempts: 5, delay: 4.0))
    sink.call(Mistri::Event.new(type: :error, reason: :rate_limit, error_message: "slow down"))

    assert_match(/INFO \[mistri\] turn 1 done tool_use/, io.string)
    assert_match(/INFO \[mistri\] turn 2 done stop/, io.string)
    assert_match(%r{WARN \[mistri\] retry 2/5 in 4.0s: rate limited}, io.string)
    assert_match(/ERROR \[mistri\] error rate_limit: slow down/, io.string)
  end

  def test_frames_a_run_with_input_and_result
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)
    cost = Mistri::Usage::Cost.new(input: 0.003, output: 0.0012, cache_read: 0.0,
                                   cache_write: 0.0, total: 0.0042)
    usage = Mistri::Usage.new(input: 500, output: 60, cost: cost)

    sink.run_started(verb: "run", input: "What is 2 plus 3?", model: "fake-1", tool_count: 1)
    sink.call(Mistri::Event.new(type: :done, reason: :stop))
    sink.run_finished(Mistri::Result.new(message: nil, status: :completed, usage: usage))

    assert_match(/INFO \[mistri\] run "What is 2 plus 3\?" \(fake-1, 1 tool\)/, io.string)
    assert_match(%r{INFO \[mistri\] done completed in \d+m?s, 1 turn, 500 in / 60 out, \$0.0042},
                 io.string)
  end

  def test_renders_suspension_and_crashes
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.run_started(verb: "run", input: "send it", model: "fake-1", tool_count: 2)
    sink.run_finished(Mistri::Result.new(message: nil, status: :awaiting_approval,
                                         pending: [tool_call("send_gift")]))
    sink.run_crashed(RuntimeError.new("boom"))

    assert_match(/INFO \[mistri\] done suspended \(1 approval pending\)/, io.string)
    assert_match(/ERROR \[mistri\] crashed RuntimeError: boom/, io.string)
  end

  def test_truncates_long_values_and_reports_sizes
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger, truncate: 20)

    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("read"),
                                content: "x" * 5000, tool_error: false))

    assert_match(/tool read ok "x{1,20}\.\.\." \(4.9KB\)/, io.string)
  end

  def test_color_paints_tool_names_only_when_asked
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger, color: true)

    sink.call(Mistri::Event.new(type: :tool_started, tool_call: tool_call("add")))

    assert_includes io.string, "\e[32madd\e[0m"
  end

  def test_a_broken_logger_never_raises_and_warns_once
    broken = Object.new
    def broken.info(*) = raise "io dead"
    sink = Mistri::Sinks::Logger.new(broken)
    event = Mistri::Event.new(type: :text_end, content_index: 0, content: "hi")

    assert_output(nil, /logging sink failed.*logging disabled/) { sink.call(event) }
    assert_silent { sink.call(event) }
  end

  def test_for_session_tags_lines_with_the_session
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger).for_session("0a1b2c3d-ffff-4444-aaaa-000000000000")

    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "hi"))

    assert_match(/\[mistri 0a1b2c3d\] text "hi"/, io.string)
  end

  def test_a_run_logs_its_whole_story
    logger, io = capture
    Mistri.logger = logger
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "add",
                                                              arguments: { "a" => 2,
                                                                           "b" => 3 } }] },
                                             { text: "The sum is 5." }
                                           ])
    add = Mistri::Tool.define("add", "Add.", schema: lambda {
      integer :a, "First number", required: true
      integer :b, "Second number", required: true
    }) { |args| (args["a"] + args["b"]).to_s }

    result = Mistri::Agent.new(provider:, tools: [add]).run("What is 2 plus 3?")

    assert_predicate result, :completed?
    log = io.string

    assert_match(/run "What is 2 plus 3\?" \(fake-1, 1 tool\)/, log)
    assert_match(/tool add \{"a":2,"b":3\}/, log)
    assert_match(/tool add ok/, log)
    assert_match(/turn 1 done tool_use/, log)
    assert_match(/text "The sum is 5\."/, log)
    assert_match(/turn 2 done stop/, log)
    assert_match(/done completed in/, log)
    assert_match(/\[mistri [0-9a-f]{8}\]/, log)
  end

  def test_the_callers_block_still_sees_every_event
    logger, = capture
    Mistri.logger = logger
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Hello!" }])
    seen = []

    Mistri::Agent.new(provider:).run("hi") { |event| seen << event.type }

    assert_includes seen, :text_delta
    assert_includes seen, :done
  end

  def test_subscriber_failures_still_propagate_and_log_the_crash
    logger, io = capture
    Mistri.logger = logger
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Hello!" }])

    assert_raises(Boom) do
      Mistri::Agent.new(provider:).run("hi") do |event|
        raise Boom, "host sink died" if event.type == :done
      end
    end
    assert_match(/crashed TestLoggerSink::Boom: host sink died/, io.string)
  end

  def test_sub_agents_log_once_each_under_their_own_session
    logger, io = capture
    Mistri.logger = logger
    child_provider = Mistri::Providers::Fake.new(turns: [{ text: "Paris." }])
    researcher = Mistri::SubAgent.new(name: "researcher", description: "Answers questions.",
                                      provider: child_provider)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "researcher",
                                                              arguments: {
                                                                "task" => "Capital of France?"
                                                              } }] },
                                             { text: "It is Paris." }
                                           ])

    Mistri::Agent.new(provider:, tools: [researcher.tool]).run("Ask the researcher.")

    log = io.string

    assert_equal 1, log.scan('text "Paris."').length,
                 "the child's answer logs once, from the child's own agent"
    assert_equal 1, log.scan('text "It is Paris."').length
    assert_match(/run "Capital of France\?"/, log)
    assert_equal 2, log.scan(/\[mistri ([0-9a-f]{8})\]/).uniq.length,
                 "parent and child log under their own session tags"
  end

  def test_no_logger_means_no_logging
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Hello!" }])

    result = nil
    assert_silent { result = Mistri::Agent.new(provider:).run("hi") }

    assert_predicate result, :completed?
  end
end
