# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "wasmtime"
require_relative "../sandbox"

module Mistri
  module Sandbox
    # JavaScript in QuickJS compiled to WebAssembly, run by wasmtime inside the
    # host's process. Not auto-required, because wasmtime is an optional gem.
    # The pinned build is quickjs.wasm of the npm package quickjs-wasi 3.7.0.
    # Every import of the module is defined below, so the code reaches nothing
    # else. While the code computes it holds the interpreter lock. It passes
    # the lock on at QuickJS's interrupt checks, which one built-in call never
    # makes, so other threads can wait for as long as timeout.
    class QuickJS
      SHA256 = "c0bd8f296e18cf074969f6401b9ecb72609a1323818ec2b9bf7a8f8d740d1363"
      WASI = "wasi_snapshot_preview1"
      EXPORTS = %w[
        _initialize qjs_init qjs_eval qjs_new_string qjs_get_string_len qjs_free_cstring
        qjs_free_value qjs_is_exception qjs_get_exception qjs_execute_pending_job
        qjs_is_job_pending qjs_set_memory_limit qjs_set_interrupt_handler qjs_get_global
        qjs_set_prop_string qjs_new_host_function qjs_set_max_stack_size wasm_malloc wasm_free
      ].freeze
      PRELUDE = <<~JS
        (() => {
          const host = globalThis.__host;
          delete globalThis.__host;
          const { stringify, parse } = JSON;
          const wellFormed = Function.prototype.call.bind(String.prototype.toWellFormed);
          // A string cut inside an emoji holds half of a pair, which UTF-8 cannot carry.
          const sendable = (_key, value) => typeof value === "string" ? wellFormed(value) : value;
          const call = (op, payload) => {
            const reply = parse(host(stringify({ __proto__: null, op, ...payload }, sendable)));
            if (reply.error !== undefined) throw new Error(reply.error);
            return reply.value;
          };
          globalThis.files = Object.freeze({
            read: (path) => call("read", { path }),
            write: (path, content) => call("write", { path, content: String(content) }),
            list: (prefix) => call("list", { prefix }),
            delete: (path) => call("delete", { path }),
          });
          const text = (part) => typeof part === "string" ? part : stringify(part);
          const say = (...parts) => call("print", { text: parts.map(text).join(" ") });
          globalThis.console = Object.freeze({ log: say, info: say, warn: say, error: say });
          globalThis.tools = new Proxy({}, {
            get: (_target, name) => async (args) => call("tool", { name, arguments: args || {} }),
          });
          const failed = (error) => call("throw", {
            message: error && error.stack ? String(error) + "\\n" + error.stack : String(error),
          });
          globalThis.__run = (body) => {
            const AsyncFunction = (async () => {}).constructor;
            let run;
            try {
              run = new AsyncFunction(body);
            } catch (error) {
              return failed(error);
            }
            run().then(
              (value) => {
                try {
                  call("return", { value: value === undefined ? null : value });
                } catch (error) {
                  call("throw", { message: "The value the code returned cannot be sent: " + error });
                }
              },
              failed,
            );
          };
        })();
      JS
      FORKED = "this process was forked after the sandbox had run code in its parent, and " \
               "wasmtime does not survive a fork. Run code only in the forked processes, or " \
               "build the sandbox in each of them."
      MAX_PRINTED_BYTES = 100_000
      # Below what wasmtime allows a call stack, so deep recursion is an error
      # the code can catch and not a trap.
      MAX_STACK_BYTES = 128 * 1024
      private_constant :WASI, :EXPORTS, :PRELUDE, :FORKED, :MAX_PRINTED_BYTES, :MAX_STACK_BYTES

      def initialize(wasm:, timeout: 10, total_timeout: 300, memory: 64 * 1024 * 1024,
                     sha256: SHA256)
        @wasm = File.binread(wasm)
        unless Digest::SHA256.hexdigest(@wasm) == sha256
          raise ConfigurationError, "#{wasm} is not the QuickJS build this adapter was written for"
        end

        @limits = { timeout:, total_timeout:, memory: }
        @building = Mutex.new
      end

      def run(code, host:)
        engine, wasm_module = engine_here
        Run.new(engine, wasm_module, host, **@limits).call(code)
      rescue Wasmtime::Error => e
        raise Stopped, "the code was stopped: #{e.message.lines.first.to_s.strip}"
      end

      private

      # wasmtime's engine and its timer do not survive a fork, so a process
      # builds its own at its first run, from the bytes that were checked: the
      # file can be replaced by then.
      def engine_here
        pid, engine, wasm_module = @built || @building.synchronize { @built ||= build }
        raise ConfigurationError, FORKED unless pid == Process.pid

        [engine, wasm_module]
      end

      def build
        engine = Wasmtime::Engine.new(epoch_interruption: true)
        engine.start_epoch_interval(50)
        [Process.pid, engine, Wasmtime::Module.new(engine, @wasm)]
      end

      # One run in one new instance.
      class Run
        def initialize(engine, wasm_module, host, timeout:, total_timeout:, memory:)
          @host = host
          @timeout = timeout
          @total_timeout = total_timeout
          @memory = memory
          @deadline = now + timeout
          @ends = now + total_timeout
          @output = []
          @printed = 0
          @dropped = 0
          @store = Wasmtime::Store.new(engine, nil,
                                       limits: { memory_size: memory + (16 * 1024 * 1024) })
          @store.set_epoch_deadline((timeout * 20) + 4)
          instance = linker(engine).instantiate(@store, wasm_module)
          @call = EXPORTS.to_h { |name| [name.to_sym, instance.export(name).to_func] }
          @bytes = instance.export("memory").to_memory
        end

        def call(code)
          start
          evaluate(PRELUDE, "prelude.js")
          evaluate("__run(#{JSON.generate(code)})", "code.js")
          run_jobs
          raise Stopped, unfinished unless @returned || @thrown

          Outcome.new(value: @value, output: printed, error: @thrown)
        end

        private

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # A job that throws outside a promise, as a callback of queueMicrotask
        # does, leaves the job that reports the return value unrun.
        def run_jobs
          until @call[:qjs_is_job_pending].call.zero?
            next unless @call[:qjs_execute_pending_job].call.negative?
            raise Stopped, unfinished if now > @deadline

            return @thrown ||= read(@call[:qjs_get_exception].call)
          end
        end

        def unfinished
          now > @deadline ? "it ran for #{@timeout} seconds" : "it ended without returning"
        end

        def start
          @call[:_initialize].call
          raise Error, "QuickJS did not start" unless @call[:qjs_init].call.zero?

          @call[:qjs_set_memory_limit].call(@memory)
          @call[:qjs_set_max_stack_size].call(MAX_STACK_BYTES)
          @call[:qjs_set_interrupt_handler].call(1)
          name, length = write("__host")
          function = @call[:qjs_new_host_function].call(name, length, 0)
          @call[:qjs_set_prop_string].call(@call[:qjs_get_global].call, name, function)
          @call[:wasm_free].call(name)
        end

        def linker(engine)
          linker = Wasmtime::Linker.new(engine)
          system_imports(linker)
          refused_imports(linker)
          linker.func_new("env", "host_interrupt", [], [:i32]) do |_caller|
            Thread.pass
            now > @deadline ? 1 : 0
          end
          linker.func_new("env", "host_promise_rejection", %i[i32 i32 i32], []) do |_caller, *held|
            held.first(2).each { |value| @call[:qjs_free_value].call(value) }
            nil
          end
          linker.func_new("env", "host_call", %i[i32 i32 i32 i32 i32], [:i32]) do |_caller, *values|
            count, pointer = values.last(2)
            request = count.positive? ? read(@bytes.read(pointer, 4).unpack1("V")) : "{}"
            string(JSON.generate(answer(request)))
          end
          linker
        end

        def system_imports(linker)
          linker.func_new(WASI, "clock_time_get", %i[i32 i64 i32], [:i32]) do |caller, id, *values|
            clock = id.zero? ? Process::CLOCK_REALTIME : Process::CLOCK_MONOTONIC
            time = Process.clock_gettime(clock, :nanosecond)
            memory_of(caller).write(values.last, [time].pack("Q<"))
            0
          end
          linker.func_new(WASI, "random_get", %i[i32 i32], [:i32]) do |caller, pointer, length|
            memory_of(caller).write(pointer, SecureRandom.random_bytes(length))
            0
          end
          linker.func_new(WASI, "fd_write", %i[i32 i32 i32 i32], [:i32]) do |caller, *values|
            _fd, vectors, count, written = values
            memory = memory_of(caller)
            lengths = (0...count).map { |index| memory.read(vectors + (index * 8) + 4, 4) }
            total = lengths.sum { |length| length.unpack1("V") }
            memory.write(written, [total].pack("V"))
            0
          end
        end

        def refused_imports(linker)
          linker.func_new(WASI, "fd_close", [:i32], [:i32]) { |_caller, _fd| 52 }
          linker.func_new(WASI, "fd_fdstat_get", %i[i32 i32], [:i32]) { |_caller, *| 8 }
          linker.func_new(WASI, "fd_seek", %i[i32 i64 i32 i32], [:i32]) { |_caller, *| 52 }
          linker.func_new("env", "host_get_timezone_offset", %i[i32 i32], [:i32]) { |_caller, *| 0 }
          linker.func_new("env", "host_module_normalize", %i[i32 i32], [:i32]) { |_caller, *| 0 }
          linker.func_new("env", "host_module_load", %i[i32 i32], [:i32]) { |_caller, *| 0 }
        end

        def memory_of(caller) = caller.export("memory").to_memory

        def answer(text)
          request = JSON.parse(text)
          operation = request.delete("op")
          case operation
          when "print" then keep(request["text"].to_s)
          when "return"
            @returned = true
            @value = request["value"]
          when "throw" then @thrown = own_frames(request["message"].to_s)
          else return { "value" => asked(operation, request) }
          end
          { "value" => nil }
        rescue JSON::ParserError => e
          { "error" => "the call could not be read: #{e.message}" }
        rescue Error => e
          { "error" => e.message }
        end

        # The code is the body of a function whose source begins two lines
        # above it, and the frames of the adapter name nothing the code wrote.
        def own_frames(trace)
          lines = trace.lines
          lines.each_with_index.filter_map do |line, index|
            next line unless line.match?(/\A\s+at /)
            next if line.match?(/\((prelude|code)\.js:|AsyncFunction \(native\)/)

            parsed = lines[index + 1].to_s.include?("Function (native)")
            next line unless parsed || line.include?("(<input>:")

            line.sub(/<input>:(\d+)/) { "<input>:#{Regexp.last_match(1).to_i - 2}" }
          end.join.rstrip
        end

        def asked(operation, request)
          if now > @ends
            raise Error, "the run passed its limit of #{@total_timeout} seconds, so no more " \
                         "calls are answered"
          end

          unclocked { @host.call(operation, request) }
        end

        def keep(text)
          if @dropped.zero? && @printed + text.bytesize <= MAX_PRINTED_BYTES
            @output << text
            @printed += text.bytesize
          else
            @dropped += text.bytesize
          end
        end

        def printed
          return @output if @dropped.zero?

          [*@output, "[#{@dropped} more bytes were printed and not kept]"]
        end

        # The limit is on the code's own computing: the time the host takes
        # to answer is given back.
        def unclocked
          started = now
          yield
        ensure
          @deadline += now - started
          @store.set_epoch_deadline(([@deadline - now, 0].max * 20).ceil + 4)
        end

        def evaluate(source, filename)
          code, length = write(source)
          file, = write(filename)
          value = @call[:qjs_eval].call(code, length, file, 0)
          @call[:wasm_free].call(code)
          @call[:wasm_free].call(file)
          return @call[:qjs_free_value].call(value) if @call[:qjs_is_exception].call(value).zero?

          raise Stopped, unfinished if now > @deadline

          raise Error, "#{filename}: #{read(@call[:qjs_get_exception].call)}"
        end

        def write(text)
          bytes = text.b
          pointer = @call[:wasm_malloc].call(bytes.bytesize + 1)
          raise Stopped, "the code ran out of memory" if pointer.zero?

          @bytes.write(pointer, "#{bytes}\0".b)
          [pointer, bytes.bytesize]
        end

        def string(text)
          pointer, length = write(text)
          @call[:qjs_new_string].call(pointer, length).tap { @call[:wasm_free].call(pointer) }
        end

        def read(value)
          slot = @call[:wasm_malloc].call(4)
          pointer = @call[:qjs_get_string_len].call(value, slot)
          length = @bytes.read(slot, 4).unpack1("V")
          @call[:wasm_free].call(slot)
          return "" if pointer.zero?

          @bytes.read(pointer, length).force_encoding(Encoding::UTF_8)
                .tap { @call[:qjs_free_cstring].call(pointer) }
        end
      end
      private_constant :Run
    end
  end
end
