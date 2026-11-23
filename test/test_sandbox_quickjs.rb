# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The QuickJS adapter. It needs the wasmtime gem and the file quickjs.wasm of
# the npm package quickjs-wasi 3.7.0, named by MISTRI_QUICKJS_WASM.
class TestSandboxQuickJS < Minitest::Test
  def setup
    wasm = ENV.fetch("MISTRI_QUICKJS_WASM", nil)
    skip "MISTRI_QUICKJS_WASM is not set" if wasm.to_s.empty?
    begin
      require "mistri/sandbox/quickjs"
    rescue LoadError
      skip "wasmtime is not installed"
    end
    @wasm = wasm
    @sandbox = SANDBOXES[wasm] ||= Mistri::Sandbox::QuickJS.new(wasm:, timeout: 1)
  end

  SANDBOXES = {} # rubocop:disable Style/MutableConstant

  def test_code_returns_prints_and_reaches_the_host_only_through_its_calls
    asked = []
    host = lambda do |operation, payload|
      asked << [operation, payload]
      operation == "read" ? "a,b\n1,2\n" : "tool said hi"
    end

    outcome = @sandbox.run(<<~JS, host:)
      const rows = files.read("data.csv").trim().split("\\n").length;
      console.log("rows", rows);
      return { rows, said: await tools.greet({ name: "Ana" }), fetch: typeof fetch, node: typeof process };
    JS

    assert_equal({ "rows" => 2, "said" => "tool said hi", "fetch" => "undefined",
                   "node" => "undefined" }, outcome.value)
    assert_equal ["rows 2"], outcome.output
    assert_equal [["read", { "path" => "data.csv" }],
                  ["tool", { "name" => "greet", "arguments" => { "name" => "Ana" } }]], asked
  end

  def test_an_error_from_the_host_is_thrown_in_the_code_and_an_uncaught_one_is_reported
    host = ->(_operation, _payload) { raise Mistri::Error, "No document at \"x\"" }

    caught = @sandbox.run('try { files.read("x") } catch (error) { return error.message }', host:)
    uncaught = @sandbox.run('files.read("x")', host:)

    assert_equal 'No document at "x"', caught.value
    assert_match(/No document at "x"/, uncaught.error)
  end

  def test_an_endless_loop_and_a_memory_bomb_are_stopped
    host = ->(_operation, _payload) {}
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    loop_error = assert_raises(Mistri::Sandbox::Stopped) { @sandbox.run("while (true) {}", host:) }
    bomb = assert_raises(Mistri::Error) do
      @sandbox.run("const a = []; while (true) a.push('x'.repeat(1e6));", host:)
    end

    assert_match(/ran for 1 seconds/, loop_error.message)
    assert_match(/out of memory/, bomb.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_a_run_makes_no_call_after_its_total_limit
    sandbox = Mistri::Sandbox::QuickJS.new(wasm: @wasm, timeout: 1, total_timeout: 0.3)
    host = lambda do |_operation, _payload|
      sleep 0.2
      "read"
    end

    outcome = sandbox.run(<<~JS, host:)
      let calls = 0;
      try { while (true) { files.read("a"); calls++; } } catch (error) { return [calls, error.message]; }
    JS

    assert_equal [2, "the run passed its limit of 0.3 seconds, so no more calls are answered"],
                 outcome.value
  end

  def test_the_code_has_the_real_time_and_new_random_numbers_in_each_run
    host = ->(_operation, _payload) {}

    first, second = Array.new(2) { @sandbox.run("return [Date.now(), Math.random()]", host:).value }

    assert_in_delta Time.now.to_f * 1000, first[0], 60_000
    refute_equal first[1], second[1]
  end

  def test_what_the_code_prints_is_kept_up_to_a_bound
    outcome = @sandbox.run(<<~JS, host: ->(_operation, _payload) {})
      const line = "x".repeat(10000);
      for (let i = 0; i < 30; i++) console.log(line);
      return 1;
    JS

    assert_equal 1, outcome.value
    assert_equal 11, outcome.output.length
    assert_equal "[200000 more bytes were printed and not kept]", outcome.output.last
  end

  def test_the_time_the_host_takes_to_answer_does_not_count_against_the_limit
    host = lambda do |_operation, _payload|
      sleep 1.3
      "late"
    end

    outcome = @sandbox.run("return await tools.slow({})", host:)
    loop_error = assert_raises(Mistri::Sandbox::Stopped) do
      @sandbox.run("await tools.slow({}); while (true) {}", host:)
    end

    assert_equal "late", outcome.value
    assert_match(/ran for 1 seconds/, loop_error.message)
  end

  FORKING = <<~RUBY
    require "mistri"
    require "mistri/sandbox/quickjs"
    sandbox = Mistri::Sandbox::QuickJS.new(wasm: ARGV.fetch(0), timeout: 1)
    host = ->(_operation, _payload) {}
    in_a_fork = lambda do
      reader, writer = IO.pipe
      pid = fork do
        writer.puts(begin
          sandbox.run("return 1 + 1", host:).value
        rescue Mistri::ConfigurationError => e
          e.class.name
        end)
        writer.close
        exit!(0)
      end
      writer.close
      Process.wait(pid)
      reader.read.strip
    end
    before = in_a_fork.call
    sandbox.run("return 1", host:)
    puts before, in_a_fork.call
  RUBY

  # A new process, because this one has run code already.
  def test_a_process_forked_before_any_run_runs_code_and_one_forked_after_is_refused
    skip "this platform does not fork" unless Process.respond_to?(:fork)

    lib = File.expand_path("../lib", __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, "-I#{lib}", "-e", FORKING, @wasm)

    assert_predicate status, :success?, output
    assert_equal %w[2 Mistri::ConfigurationError], output.lines.last(2).map(&:strip)
  end

  def test_another_build_of_the_module_is_refused
    assert_raises(Mistri::ConfigurationError) do
      Mistri::Sandbox::QuickJS.new(wasm: __FILE__)
    end
  end
end
