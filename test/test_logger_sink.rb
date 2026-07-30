# frozen_string_literal: true

require_relative "test_helper"
require "logger"
require "stringio"

# The logging sink renders the event stream as one line per beat, and
# assigning Mistri.logger makes every run log its own story exactly once,
# sub-agents included.
class TestLoggerSink < Minitest::Test # rubocop:disable Metrics/ClassLength -- one behavior test per renderer and run path adds up
  class Boom < StandardError
  end

  SCHEMA = { type: "object", properties: { "answer" => { type: "string" } },
             required: ["answer"] }.freeze

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

  # The first word after the tag, one per line: the cheapest way to pin
  # line order without matching volatile ids and timings.
  def kinds(io)
    io.string.lines.map { |line| line[/\] (\S+)/, 1] }
  end

  def test_logs_tool_calls_with_ids_arguments_duration_and_verdict
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :tool_started, tool_call: tool_call("add", { "a" => 2 })))
    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("add"),
                                content: "5", duration: 0.012, tool_error: false))

    assert_match(/INFO \[mistri\] tool add#c1 \{"a":2\}/, io.string)
    assert_match(/INFO \[mistri\] tool add#c1 ok 12ms "5"/, io.string)
  end

  def test_marks_failed_tools_at_warn
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("boom"),
                                content: "kaboom", duration: 2.34, tool_error: true))

    assert_match(/WARN \[mistri\] tool boom#c1 FAILED 2.3s "kaboom"/, io.string)
  end

  def test_run_sinks_skip_deltas_forwarded_events_and_empty_text
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger).for_session("0a1b2c3d-ffff")

    sink.call(Mistri::Event.new(type: :text_delta, content_index: 0, delta: "Hel"))
    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "from a child",
                                origin: "Corgi#ab12cd34"))
    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "  "))

    assert_empty io.string
  end

  def test_a_standalone_sink_renders_forwarded_events_with_their_origin
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "from a child",
                                origin: "Corgi#ab12cd34"))

    assert_match(/INFO \[mistri\] Corgi#ab12cd34 text "from a child"/, io.string)
  end

  def test_renders_thinking_approvals_compaction_and_worker_reports
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :thinking_end, content_index: 0,
                                content: "Weighing the options"))
    sink.call(Mistri::Event.new(type: :approval_needed,
                                tool_call: tool_call("send_gift", { "to" => "sarah" })))
    sink.call(Mistri::Event.new(type: :compacting))
    sink.call(Mistri::Event.new(type: :compaction, content: "The story so far"))
    sink.call(Mistri::Event.new(type: :subagent_report, agent: "Corgi",
                                session_id: "ef56ab12-0000-4444-aaaa-000000000000",
                                status: "done", content: "found it"))

    assert_match(/INFO \[mistri\] thinking "Weighing the options"/, io.string)
    assert_match(/INFO \[mistri\] approval needed send_gift#c1 \{"to":"sarah"\}/, io.string)
    assert_match(/INFO \[mistri\] compacting/, io.string)
    assert_match(/INFO \[mistri\] compacted "The story so far"/, io.string)
    assert_match(/INFO \[mistri\] worker Corgi \(ef56ab12\) done "found it"/, io.string)
  end

  def test_numbers_turns_counting_errored_turns_and_flags_retries
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :done, reason: :tool_use))
    sink.call(Mistri::Event.new(type: :retry, content: "rate limited", attempt: 2,
                                max_attempts: 5, delay: 4.0))
    sink.call(Mistri::Event.new(type: :error, reason: :rate_limit, error_message: "slow down"))
    sink.run_finished(Mistri::Result.new(message: nil, status: :error))

    assert_match(/INFO \[mistri\] turn 1 done tool_use/, io.string)
    assert_match(%r{WARN \[mistri\] retry 2/5 in 4.0s: rate limited}, io.string)
    assert_match(/ERROR \[mistri\] error rate_limit: slow down/, io.string)
    assert_match(/ERROR \[mistri\] done error in \d+m?s, 2 turns/, io.string)
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

  def test_renders_every_terminal_status
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.run_finished(Mistri::Result.new(message: nil, status: :awaiting_approval,
                                         pending: [tool_call("send_gift")]))
    sink.run_finished(Mistri::Result.new(message: nil, status: :completed, handed_off: true))
    sink.run_finished(Mistri::Result.new(message: nil, status: :aborted))
    sink.run_finished(Mistri::Result.new(message: nil, status: :budget))
    sink.run_crashed(RuntimeError.new("boom"))

    assert_match(/INFO \[mistri\] done suspended \(1 approval pending\)/, io.string)
    assert_match(/INFO \[mistri\] done completed \(handed off\)/, io.string)
    assert_match(/INFO \[mistri\] done aborted/, io.string)
    assert_match(/WARN \[mistri\] done stopped on budget/, io.string)
    assert_match(/ERROR \[mistri\] crashed RuntimeError: boom/, io.string)
  end

  def test_truncates_long_values_and_reports_original_sizes
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger, truncate: 20)

    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("read"),
                                content: "x" * 5000, tool_error: false))

    assert_match(/tool read#c1 ok "x{1,20}\.\.\." \(4.9KB\)/, io.string)
  end

  def test_expected_stops_log_calmly_and_budget_never_counts_a_turn
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :done, reason: :stop))
    sink.call(Mistri::Event.new(type: :error, reason: :budget))
    sink.run_finished(Mistri::Result.new(message: nil, status: :budget))
    sink.call(Mistri::Event.new(type: :error, reason: :aborted))

    assert_match(/WARN \[mistri\] stopped on budget$/, io.string)
    assert_match(/WARN \[mistri\] done stopped on budget in \d+m?s, 1 turn/, io.string)
    assert_match(/INFO \[mistri\] aborted/, io.string)
    refute_match(/ERROR/, io.string)
  end

  def test_counts_cached_prompt_tokens
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)
    usage = Mistri::Usage.new(input: 10, output: 22, cache_read: 850, cache_write: 40)

    sink.run_finished(Mistri::Result.new(message: nil, status: :completed, usage: usage))

    assert_match(%r{done completed in \d+m?s, 0 turns, 900 in \(890 cached\) / 22 out}, io.string)
  end

  def test_escapes_control_characters_in_untrusted_content
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :text_end, content_index: 0,
                                content: "hi \e[31mboo\u0000tail"))

    assert_includes io.string, 'text "hi \u001b[31mboo\u0000tail"'
  end

  def test_no_size_suffix_when_only_whitespace_collapsed
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("read"),
                                content: "#{"x" * 100}#{" " * 500}", tool_error: false))

    assert_match(/tool read#c1 ok "x{100}"/, io.string)
    refute_match(/B\)/, io.string)
  end

  def test_level_floors_the_ordinary_lines_only
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger, level: :debug)

    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "hi"))
    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("boom"),
                                content: "bad", tool_error: true))

    assert_match(/DEBUG \[mistri\] text "hi"/, io.string)
    assert_match(/WARN \[mistri\] tool boom#c1 FAILED/, io.string)
  end

  def test_color_paints_tool_names_only_when_asked
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger, color: true)

    sink.call(Mistri::Event.new(type: :tool_started, tool_call: tool_call("add")))

    assert_includes io.string, "\e[32madd\e[0m#c1"
  end

  def test_a_broken_logger_never_raises_and_warns_once
    broken = Object.new
    def broken.info(*) = raise "io dead"
    sink = Mistri::Sinks::Logger.new(broken)
    event = Mistri::Event.new(type: :text_end, content_index: 0, content: "hi")

    assert_output(nil, /logging sink failed.*logging disabled/) { sink.call(event) }
    assert_silent { sink.call(event) }
    assert_silent { sink.run_started(verb: "run", model: "m", tool_count: 0) }
  end

  def test_framing_is_total_on_a_broken_logger
    broken = Object.new
    def broken.info(*) = raise "io dead"
    sink = Mistri::Sinks::Logger.new(broken)

    assert_output(nil, /logging sink failed/) do
      sink.run_started(verb: "run", model: "m", tool_count: 0)
    end
  end

  def test_for_session_tags_lines_with_the_session_or_a_label
    logger, io = capture
    base = Mistri::Sinks::Logger.new(logger)

    base.for_session("0a1b2c3d-ffff-4444-aaaa-000000000000")
        .call(Mistri::Event.new(type: :text_end, content_index: 0, content: "hi"))
    base.for_session("0a1b2c3d-ffff-4444-aaaa-000000000000", label: "researcher#0a1b2c3d")
        .call(Mistri::Event.new(type: :text_end, content_index: 0, content: "ho"))

    assert_match(/\[mistri 0a1b2c3d\] text "hi"/, io.string)
    assert_match(/\[mistri researcher#0a1b2c3d\] text "ho"/, io.string)
  end

  def test_rejects_junk_assignments_at_assignment_time
    assert_raises(Mistri::ConfigurationError) { Mistri.logger = Object.new }
    assert_raises(Mistri::ConfigurationError) do
      Mistri.logger = Mistri::Sinks::Coalesced.new(->(_event) {})
    end

    Mistri.logger = capture.first
    Mistri.logger = Mistri::Sinks::Logger.new(capture.first)
    Mistri.logger = nil
  end

  def test_a_run_logs_its_whole_story_in_order
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
    # The model's turn genuinely completes before its tools execute, so the
    # turn line precedes the tool lines. This order is the README example's
    # source of truth.
    assert_equal %w[run turn tool tool text turn done], kinds(io)
    log = io.string

    assert_match(/run "What is 2 plus 3\?" \(fake-1, 1 tool\)/, log)
    assert_match(/tool add#\S+ \{"a":2,"b":3\}/, log)
    assert_match(/tool add#\S+ ok/, log)
    assert_match(/text "The sum is 5\."/, log)
    assert_match(/done completed in/, log)
    assert_match(/\[mistri [0-9a-f]{8}\]/, log)
  end

  def test_task_logs_one_frame_around_its_fix_passes
    logger, io = capture
    Mistri.logger = logger
    provider = Mistri::Providers::Fake.new(turns: [
                                             { text: '{"answer": 41}' },
                                             { text: '{"answer": "42"}' }
                                           ])

    result = Mistri::Agent.new(provider:).task("The answer?", schema: SCHEMA)

    assert_equal({ "answer" => "42" }, result.output)
    assert_equal %w[task text turn text turn done], kinds(io)
    assert_match(/task "The answer\?" \(fake-1, 0 tools\)/, io.string)
    assert_match(/done completed in \d+m?s, 2 turns/, io.string)
  end

  def test_resume_frames_its_outcomes_including_still_pending
    logger, io = capture
    Mistri.logger = logger
    gated = Mistri::Tool.define("send_gift", "Sends.", needs_approval: true) { "sent" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send_gift",
                                                              arguments: {} }] },
                                             { text: "Sent it." }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [gated])

    suspended = agent.run("send sarah a gift")
    agent.resume
    agent.session.approve(suspended.pending.fetch(0).id)
    finished = agent.resume

    assert_predicate finished, :completed?
    log = io.string

    assert_match(/approval needed send_gift#\S+ \{\}/, log)
    assert_equal 2, log.scan("done suspended (1 approval pending)").length,
                 "the run frame and the still-pending resume frame both report suspension"
    assert_equal 2, log.scan("resume (fake-1, 1 tool)").length
    assert_match(/tool send_gift#\S+ ok/, log)
    assert_match(/done completed in/, log)
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

  def test_an_invalid_byte_crash_keeps_the_hosts_exception
    logger, io = capture
    Mistri.logger = logger
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Hello!" }])
    bad = "boom \xFF".dup.force_encoding(Encoding::UTF_8)

    error = assert_raises(Boom) do
      Mistri::Agent.new(provider:).run("hi") do |event|
        raise Boom, bad if event.type == :done
      end
    end

    assert_instance_of Boom, error
    assert_match(/crashed TestLoggerSink::Boom/, io.string)
  end

  def test_sub_agents_log_once_each_under_their_own_label
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
    assert_match(/\[mistri researcher#[0-9a-f]{8}\] run "Capital of France\?"/, log)
    assert_match(/\[mistri [0-9a-f]{8}\] run "Ask the researcher\."/, log)
  end

  def test_content_off_keeps_the_story_without_the_words
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger, content: false)

    sink.run_started(verb: "run", input: "the secret question", model: "fake-1", tool_count: 1)
    sink.call(Mistri::Event.new(type: :tool_started,
                                tool_call: tool_call("add", { "secret" => "value" })))
    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("add"),
                                content: "secret answer", duration: 0.012, tool_error: false))
    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "secret text"))

    refute_includes io.string, "secret"
    assert_match(/run \(fake-1, 1 tool\)/, io.string)
    assert_match(/tool add#c1$/, io.string)
    assert_match(/tool add#c1 ok 12ms \(13B\)/, io.string)
    assert_match(/text \(11B\)/, io.string)
  end

  def test_hidden_bytes_in_labels_and_names_cannot_forge_lines
    logger, io = capture
    forged = "evil\nINFO [mistri] fake line\u202e"
    sink = Mistri::Sinks::Logger.new(logger).for_session("id", label: forged)

    sink.call(Mistri::Event.new(type: :tool_started,
                                tool_call: Mistri::ToolCall.new(id: "c1", name: "na\u0085me")))

    assert_equal 1, io.string.lines.length, "a hidden byte must never mint an extra line"
    assert_includes io.string, "\\u202e"
    assert_includes io.string, "na\\u0085me"
  end

  def test_rejects_bad_options_at_construction_time
    logger, = capture

    assert_raises(ArgumentError) { Mistri::Sinks::Logger.new(logger, level: :loud) }
    assert_raises(ArgumentError) { Mistri::Sinks::Logger.new(logger, truncate: -1) }
    assert_raises(ArgumentError) { Mistri::Sinks::Logger.new(logger, forwarded: :maybe) }
  end

  def test_a_raising_sink_factory_never_breaks_the_run
    factory = Object.new
    def factory.for_session(*) = raise "factory died"
    Mistri.logger = factory
    provider = Mistri::Providers::Fake.new(turns: [{ text: "hi" }])

    result = nil
    assert_output(nil, /logging sink construction failed/) do
      result = Mistri::Agent.new(provider:).run("hello")
    end

    assert_predicate result, :completed?
  end

  def test_the_global_requires_the_full_severity_contract
    half = Object.new
    def half.info(*); end

    assert_raises(Mistri::ConfigurationError) { Mistri.logger = half }
  end

  def test_argument_previews_stay_bounded
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)
    huge = { "blob" => "x" * 2_000_000, "list" => Array.new(2_000) { "v" } }

    sink.call(Mistri::Event.new(type: :tool_started, tool_call: tool_call("save", huge)))

    line = io.string.lines.fetch(0)

    assert_operator line.length, :<, 400, "a huge argument tree must render as a bounded preview"
    assert_includes line, "..."
  end

  def test_renders_argument_errors_instead_of_arguments
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)
    call = Mistri::ToolCall.new(id: "c1", name: "add", arguments_error: "too_large")

    sink.call(Mistri::Event.new(type: :tool_started, tool_call: call))

    assert_match(/tool add#c1 \[.*too_large.*\]/, io.string)
  end

  def test_skips_formatting_when_the_floor_level_is_disabled
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.level = ::Logger::WARN
    sink = Mistri::Sinks::Logger.new(logger)

    sink.run_started(verb: "run", input: "hi", model: "fake-1", tool_count: 0)
    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "quiet"))
    sink.call(Mistri::Event.new(type: :tool_result, tool_call: tool_call("boom"),
                                content: "bad", tool_error: true))

    refute_includes io.string, "quiet"
    assert_includes io.string, "FAILED"
  end

  def test_store_failures_get_a_crash_line
    logger, io = capture
    Mistri.logger = logger
    store = Class.new(Mistri::Stores::Memory) do
      def append(*) = raise "store down"
    end.new
    provider = Mistri::Providers::Fake.new(turns: [{ text: "hi" }])
    agent = Mistri::Agent.new(provider:, session: Mistri::Session.new(store: store))

    assert_raises(RuntimeError) { agent.run("hello") }
    assert_match(/run "hello"/, io.string)
    assert_match(/crashed RuntimeError: store down/, io.string)
  end

  def test_known_free_usage_stays_distinguishable_from_unpriced
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)

    sink.run_finished(Mistri::Result.new(message: nil, status: :completed,
                                         usage: Mistri::Usage.zero))
    sink.run_finished(Mistri::Result.new(message: nil, status: :completed,
                                         usage: Mistri::Usage.new))

    lines = io.string.lines

    assert_includes lines.fetch(0), "$0.0000"
    refute_includes lines.fetch(1), "$"
  end

  def test_every_entry_point_contains_its_own_failures
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger)
    poison = Object.new
    def poison.to_s = raise "unrenderable"

    assert_output(nil, /logging sink failed/) do
      sink.call(Mistri::Event.new(type: :retry, content: "note", attempt: 1,
                                  max_attempts: 2, delay: poison))
    end
    [-> { sink.run_started(verb: "run", input: poison, model: "m", tool_count: 0) },
     -> { sink.run_finished(nil) },
     -> { sink.run_crashed(nil) },
     -> { sink.call(Mistri::Event.new(type: :done, reason: :stop)) }].each do |entry|
      assert_silent { entry.call }
    end
    assert_empty io.string.lines.grep(/unrenderable/)
  end

  def test_a_raising_level_query_counts_as_enabled
    io = StringIO.new
    logger = ::Logger.new(io)
    def logger.info? = raise "gauge broken"
    sink = Mistri::Sinks::Logger.new(logger)

    sink.call(Mistri::Event.new(type: :text_end, content_index: 0, content: "still here"))

    assert_includes io.string, "still here"
  end

  def test_argument_previews_cut_inside_collections
    logger, io = capture
    sink = Mistri::Sinks::Logger.new(logger, truncate: 30)
    call = tool_call("list", { "items" => ["x" * 40, "second", "third"] })

    sink.call(Mistri::Event.new(type: :tool_started, tool_call: call))

    assert_includes io.string, "..."
    refute_includes io.string, "third"
  end

  def test_no_logger_builds_no_sink
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Hello!" }])
    built = false
    original = Mistri::Sinks::Logger.method(:new)
    Mistri::Sinks::Logger.define_singleton_method(:new) do |*args, **options|
      built = true
      original.call(*args, **options)
    end

    result = Mistri::Agent.new(provider:).run("hi")

    assert_predicate result, :completed?
    refute built, "with no logger assigned, no sink should ever be constructed"
  ensure
    Mistri::Sinks::Logger.singleton_class.remove_method(:new)
  end
end
