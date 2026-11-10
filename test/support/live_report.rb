# frozen_string_literal: true

require "minitest"

module Mistri
  module Test
    # What a run's calls to the vendors cost: for each model the calls, the
    # seconds waited, the tokens and the dollars at catalog prices, then the
    # slowest tests. It is an estimate from the usage each call reported, not
    # a bill. A call to a stub server is not counted.
    class LiveReport
      SLOWEST = 10
      HEADINGS = ["model", "calls", "seconds", "input", "cache read", "cache write",
                  "output", "dollars"].freeze

      Call = Data.define(:model, :seconds, :usage)

      # Prints the report after Minitest's own summary.
      class Reporter < Minitest::AbstractReporter
        def initialize(io, live_report)
          super()
          @io = io
          @live_report = live_report
          @tests = []
        end

        def record(result)
          @tests << [result.time, "#{result.klass}##{result.name}"]
        end

        def report
          @io.puts(@live_report.summary(@tests)) unless @live_report.calls.empty?
        end
      end

      class << self
        def install
          return if @installed

          @installed = new
          Mistri::PROVIDERS.each_value do |provider|
            provider.prepend(@installed.recorder(provider::DEFAULT_ORIGIN))
          end
          Minitest.register_plugin(self)
        end

        def minitest_plugin_init(options)
          Minitest.reporter << Reporter.new(options[:io], @installed)
        end
      end

      def initialize
        @calls = []
        @billed = ObjectSpace::WeakMap.new
        @mutex = Mutex.new
      end

      # A module to prepend to a provider class. A provider built on the
      # vendor's origin makes real calls, and those are recorded.
      def recorder(vendor)
        report = self
        billed = @billed
        Module.new do
          define_method(:initialize) do |**options|
            super(**options)
            origin = options.fetch(:origin, vendor).to_s.delete_suffix("/")
            billed[self] = true if origin == vendor
          end

          define_method(:stream) do |**request, &emit|
            report.timed(self, request.fetch(:model, model)) { super(**request, &emit) }
          end
        end
      end

      # A call that raises, as when a test's own block does, was still sent:
      # it is kept, with no usage.
      def timed(provider, model)
        return yield unless @billed.key?(provider)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        usage = Usage.new
        begin
          yield.tap { |message| usage = message.usage }
        ensure
          seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          @mutex.synchronize { @calls << Call.new(model:, seconds:, usage:) }
        end
      end

      def calls = @mutex.synchronize { @calls.dup }

      def summary(tests)
        recorded = calls
        ["", "Live calls", *table(recorded), *unpriced(recorded),
         "", "Slowest tests", *slowest(tests)].join("\n")
      end

      private

      def table(recorded)
        models = recorded.group_by(&:model).sort_by { |_model, calls| -dollars(calls) }
        rows = models.map { |model, calls| row(model, calls) }
        rows << row("total", recorded) if rows.length > 1
        lines = [HEADINGS, *rows]
        widths = lines.transpose.map { |column| column.map(&:length).max }
        lines.map do |label, *numbers|
          cells = [label.ljust(widths.first),
                   *numbers.zip(widths.drop(1)).map { |number, width| number.rjust(width) }]
          "  #{cells.join("  ")}"
        end
      end

      def row(label, calls)
        usage = calls.sum(Usage.zero, &:usage)
        [label, count(calls.length), format("%.1f", calls.sum(&:seconds)),
         count(usage.input), count(usage.cache_read), count(usage.cache_write),
         count(usage.output), format("%.4f", dollars(calls))]
      end

      # Only a known cost counts. A call cut short keeps a partial figure
      # its provider no longer vouches for.
      def dollars(calls)
        calls.sum { |call| call.usage.cost.known? ? call.usage.cost.total : 0.0 }
      end

      # A call that failed, was cut short or raised has no known cost, which
      # makes the dollars a floor.
      def unpriced(recorded)
        missing = recorded.count { |call| !call.usage.cost.known? }
        return [] if missing.zero?

        ["  #{count(missing)} of these calls had no price. The dollars leave them out."]
      end

      def slowest(tests)
        tests.max_by(SLOWEST, &:first).map do |seconds, name|
          format("  %<seconds>6.1f s  %<name>s", seconds:, name:)
        end
      end

      def count(number) = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end
  end
end
