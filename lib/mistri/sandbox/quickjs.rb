# frozen_string_literal: true

require "digest"
require "json"
require "wasmtime"
require_relative "../sandbox"

module Mistri
  module Sandbox
    # JavaScript in QuickJS compiled to WebAssembly, run by wasmtime inside the
    # host's process. Not auto-required: add the wasmtime gem and
    #
    #   require "mistri/sandbox/quickjs"
    #   sandbox = Mistri::Sandbox::QuickJS.new(wasm: "vendor/quickjs.wasm")
    #
    # wasm is the file quickjs.wasm of the npm package quickjs-wasi, version
    # 3.7.0. Another build is refused unless its SHA-256 is passed. The module
    # imports twelve functions and every one is a block below, so the code
    # reaches nothing else. Each run gets a new instance with its own memory.
    #
    # A run holds the interpreter lock while the code computes: other threads
    # of the process wait until the code calls out or reaches its deadline.
    class QuickJS
      SHA256 = "c0bd8f296e18cf074969f6401b9ecb72609a1323818ec2b9bf7a8f8d740d1363"
      WASI = "wasi_snapshot_preview1"
      EXPORTS = %w[
        _initialize qjs_init qjs_eval qjs_new_string qjs_get_string_len qjs_free_cstring
        qjs_free_value qjs_is_exception qjs_get_exception qjs_execute_pending_job
        qjs_is_job_pending qjs_set_memory_limit qjs_set_interrupt_handler qjs_get_global
        qjs_set_prop_string qjs_new_host_function wasm_malloc wasm_free
      ].freeze
      # What the code sees: files, tools and console, each a call to the host.
      PRELUDE = <<~JS
        (() => {
          const host = globalThis.__host;
          delete globalThis.__host;
          const call = (op, payload) => {
            const reply = JSON.parse(host(JSON.stringify(Object.assign({ op }, payload))));
            if (reply.error !== undefined) throw new Error(reply.error);
            return reply.value;
          };
          globalThis.files = Object.freeze({
            read: (path) => call("read", { path }),
            write: (path, content) => call("write", { path, content: String(content) }),
            list: (prefix) => call("list", { prefix }),
            delete: (path) => call("delete", { path }),
          });
          const text = (part) => typeof part === "string" ? part : JSON.stringify(part);
          const say = (...parts) => call("print", { text: parts.map(text).join(" ") });
          globalThis.console = Object.freeze({ log: say, info: say, warn: say, error: say });
          globalThis.tools = new Proxy({}, {
            get: (_target, name) => async (args) => call("tool", { name, arguments: args || {} }),
          });
          globalThis.__run = (body) => {
            const AsyncFunction = (async () => {}).constructor;
            new AsyncFunction(body)().then(
              (value) => call("return", { value: value === undefined ? null : value }),
              (error) => call("throw", {
                message: error && error.stack ? String(error) + "\\n" + error.stack : String(error),
              }),
            );
          };
        })();
      JS
      private_constant :WASI, :EXPORTS, :PRELUDE

      def initialize(wasm:, timeout: 10, memory: 64 * 1024 * 1024, sha256: SHA256)
        unless Digest::SHA256.file(wasm).hexdigest == sha256
          raise ConfigurationError, "#{wasm} is not the QuickJS build this adapter was written for"
        end

        @timeout = timeout
        @memory = memory
        @engine = Wasmtime::Engine.new(epoch_interruption: true)
        @engine.start_epoch_interval(50)
        @module = Wasmtime::Module.from_file(@engine, wasm)
      end

      def run(code, host:)
        Run.new(@engine, @module, host, @timeout, @memory).call(code)
      rescue Wasmtime::Error => e
        raise Stopped, "the code was stopped: #{e.message.lines.first.to_s.strip}"
      end

      # One run in one new instance.
      class Run
        def initialize(engine, wasm_module, host, timeout, memory)
          @host = host
          @timeout = timeout
          @memory = memory
          @deadline = now + timeout
          @output = []
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
          loop do
            break if @call[:qjs_is_job_pending].call.zero?
            break if @call[:qjs_execute_pending_job].call.negative?
          end
          raise Stopped, unfinished unless @returned || @thrown

          Outcome.new(value: @value, output: @output, error: @thrown)
        end

        private

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def unfinished
          now > @deadline ? "it ran for #{@timeout} seconds" : "it ended without returning"
        end

        def start
          @call[:_initialize].call
          raise Error, "QuickJS did not start" unless @call[:qjs_init].call.zero?

          @call[:qjs_set_memory_limit].call(@memory)
          @call[:qjs_set_interrupt_handler].call(1)
          name, length = write("__host")
          function = @call[:qjs_new_host_function].call(name, length, 0)
          @call[:qjs_set_prop_string].call(@call[:qjs_get_global].call, name, function)
          @call[:wasm_free].call(name)
        end

        # Every import of the module. The clock and the random source answer
        # constants, so the code learns nothing about the host from them.
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
            request = count.positive? ? JSON.parse(read(@bytes.read(pointer, 4).unpack1("V"))) : {}
            string(JSON.generate(answer(request)))
          end
          linker
        end

        def system_imports(linker)
          linker.func_new(WASI, "clock_time_get", %i[i32 i64 i32], [:i32]) do |caller, *values|
            memory_of(caller).write(values.last, [1_700_000_000_000_000_000].pack("Q<"))
            0
          end
          linker.func_new(WASI, "random_get", %i[i32 i32], [:i32]) do |caller, pointer, length|
            memory_of(caller).write(pointer, "\x2A".b * length)
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

        # What the code has no use for answers an error code or nothing.
        def refused_imports(linker)
          linker.func_new(WASI, "fd_close", [:i32], [:i32]) { |_caller, _fd| 52 }
          linker.func_new(WASI, "fd_fdstat_get", %i[i32 i32], [:i32]) { |_caller, *| 8 }
          linker.func_new(WASI, "fd_seek", %i[i32 i64 i32 i32], [:i32]) { |_caller, *| 52 }
          linker.func_new("env", "host_get_timezone_offset", %i[i32 i32], [:i32]) { |_caller, *| 0 }
          linker.func_new("env", "host_module_normalize", %i[i32 i32], [:i32]) { |_caller, *| 0 }
          linker.func_new("env", "host_module_load", %i[i32 i32], [:i32]) { |_caller, *| 0 }
        end

        def memory_of(caller) = caller.export("memory").to_memory

        def answer(request)
          operation = request.delete("op")
          case operation
          when "print" then @output << request["text"].to_s
          when "return"
            @returned = true
            @value = request["value"]
          when "throw" then @thrown = request["message"].to_s
          else return { "value" => @host.call(operation, request) }
          end
          { "value" => nil }
        rescue StandardError => e
          { "error" => e.message }
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
