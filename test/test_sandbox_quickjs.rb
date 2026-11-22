# frozen_string_literal: true

require_relative "test_helper"

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

  def test_another_build_of_the_module_is_refused
    assert_raises(Mistri::ConfigurationError) do
      Mistri::Sandbox::QuickJS.new(wasm: __FILE__)
    end
  end
end
