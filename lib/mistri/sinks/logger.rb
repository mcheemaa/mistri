# frozen_string_literal: true

require "json"

module Mistri
  module Sinks
    # Renders the event stream as one log line per meaningful beat, so a
    # development log tells each run's whole story: which tools ran with
    # which arguments, how long each took, what every turn cost, and how
    # the run ended. Deltas never log (whole blocks do), and origin-tagged
    # events are skipped because every agent logs its own: a sub-agent's
    # lines carry its own tag exactly once, however deep the nesting
    # and whichever process runs it.
    #
    # Assigning Mistri.logger turns this on for every run in one line:
    #
    #   Mistri.logger = Rails.logger
    #   Mistri.logger = Mistri::Sinks::Logger.new(logger, color: true)
    #
    # or compose it per run like any sink, which delivers the event lines
    # only: framing (run, done) and the line tag come from the Agent, so
    # the composed form has neither.
    #
    #   agent.run(input, &Mistri::Sinks::Logger.new(logger))
    #
    # Any object responding to info/warn/error works. Logging must never
    # break a run: every entry point rescues, the first failure warns, and
    # the sink goes quiet for the rest of its run. Tool events arrive from
    # executor threads; the only mutable state (the turn counter) moves on
    # loop-thread events, and interleaved lines stay whole as long as the
    # host's logger serializes writes, which stdlib Logger and Rails do.
    class Logger
      SKIPPED = %i[start text_start text_delta thinking_start thinking_delta
                   toolcall_start toolcall_delta toolcall_end].to_h { |type| [type, true] }.freeze
      LINES = { text_end: :text_line, thinking_end: :thinking_line,
                tool_started: :tool_line, tool_result: :tool_result_line,
                done: :turn_line, error: :error_line, retry: :retry_line,
                approval_needed: :approval_line, compacting: :compacting_line,
                compaction: :compaction_line, subagent_report: :report_line }.freeze
      COLORS = { bold: "1", dim: "2", red: "31", green: "32", yellow: "33" }.freeze
      private_constant :SKIPPED, :LINES, :COLORS

      # truncate bounds every quoted value (nil for full payloads). session
      # is the line tag, verbatim, so concurrent runs stay distinguishable.
      # level is the floor for the ordinary lines: pass :debug to keep the
      # story out of a production logger sitting at :info; warnings and
      # errors keep their own levels regardless.
      def initialize(logger, session: nil, truncate: 200, color: false, level: :info)
        @logger = logger
        @session = session&.to_s
        @truncate = truncate
        @color = color
        @level = level
        @turns = 0
        @started = now
        @warned = false
        @tag = paint(@session ? "[mistri #{@session}]" : "[mistri]", :dim)
      end

      # A fresh sink for one run: same logger and options, this run's tag
      # (a sub-agent's label, or the session id), its own turn count
      # and clock.
      def for_session(id, label: nil)
        self.class.new(@logger, session: label || id.to_s[0, 8], truncate: @truncate,
                                color: @color, level: @level)
      end

      def call(event)
        return if @warned || event.origin || SKIPPED[event.type]

        handler = LINES[event.type]
        # Future event types degrade to a greppable line, never to silence.
        handler ? send(handler, event) : write("#{event.type} #{trim(event.content)}".rstrip)
      rescue StandardError => e
        quiet(e)
      end

      def to_proc = method(:call).to_proc

      # The framing the stream cannot carry: the Agent calls these around a
      # run with the input, the model, and the final Result. Each is total
      # for the same reason call is: a logging failure inside a rescue
      # block must never replace the host's own exception.
      def run_started(verb:, model:, tool_count:, input: nil)
        @turns = 0
        @started = now
        ask = input ? %( "#{trim(input)}") : ""
        write("#{paint(verb, :bold)}#{ask} (#{model}, #{count(tool_count, "tool")})")
      rescue StandardError => e
        quiet(e)
      end

      def run_finished(result)
        status, level = status_of(result)
        write("#{paint("done", :bold)} #{status} in #{clock(now - @started)}, " \
              "#{count(@turns, "turn")}#{summary(result.usage)}", level: level)
      rescue StandardError => e
        quiet(e)
      end

      def run_crashed(error)
        write("#{paint("crashed", :red)} #{error.class}: #{trim(error.message)}", level: :error)
      rescue StandardError => e
        quiet(e)
      end

      private

      def text_line(event)
        content = trim(event.content)
        write(%(text "#{content}")) unless content.empty?
      end

      def thinking_line(event)
        content = trim(event.content)
        write(%(thinking "#{content}")) unless content.empty?
      end

      def tool_line(event)
        write("tool #{title(event.tool_call)} #{arguments(event.tool_call)}")
      end

      def tool_result_line(event)
        verdict = event.tool_error? ? paint("FAILED", :red) : "ok"
        parts = ["tool #{title(event.tool_call)} #{verdict}", clock(event.duration),
                 quote(event.content)]
        write(parts.compact.join(" "), level: event.tool_error? ? :warn : :info)
      end

      def turn_line(event)
        @turns += 1
        write("turn #{@turns} done #{event.reason}#{tokens(event.message&.usage)}")
      end

      # An errored turn still made a provider call, so it counts.
      def error_line(event)
        @turns += 1
        detail = [event.reason, presence(trim(event.error_message))].compact.join(": ")
        write("#{paint("error", :red)} #{detail}", level: :error)
      end

      def retry_line(event)
        wait = event.delay ? " in #{event.delay.round(1)}s" : ""
        write("#{paint("retry", :yellow)} #{event.attempt}/#{event.max_attempts}#{wait}: " \
              "#{trim(event.content)}", level: :warn)
      end

      def approval_line(event)
        write("approval needed #{title(event.tool_call)} #{arguments(event.tool_call)}")
      end

      def compacting_line(_event) = write("compacting")

      def compaction_line(event) = write(%(compacted "#{trim(event.content)}"))

      def report_line(event)
        write("worker #{event.agent} (#{event.session_id.to_s[0, 8]}) #{event.status} " \
              "#{quote(event.content)}".rstrip)
      end

      def status_of(result)
        case result.status
        when :completed
          [result.handed_off? ? "completed (handed off)" : "completed", :info]
        when :awaiting_approval
          ["suspended (#{count(result.pending.length, "approval")} pending)", :info]
        when :aborted then ["aborted", :info]
        when :budget then ["stopped on budget", :warn]
        else [paint(result.status.to_s, :red), :error]
        end
      end

      def summary(usage)
        return "" unless usage

        base = ", #{usage.input} in / #{usage.output} out"
        cost = usage.cost
        cost&.known? && cost.total.positive? ? base + format(", $%.4f", cost.total) : base
      end

      def tokens(usage)
        usage ? " (#{usage.input} in / #{usage.output} out)" : ""
      end

      # A short call id makes concurrent same-name calls pairable and gives
      # an approval line the handle session.approve needs.
      def title(tool_call)
        return paint("?", :green) unless tool_call

        name = paint(tool_call.name, :green)
        id = tool_call.id.to_s
        ref = id.length > 4 ? id[-4, 4] : id
        ref.empty? ? name : "#{name}##{ref}"
      end

      def arguments(tool_call)
        return "[#{trim(tool_call.arguments_error)}]" if tool_call.arguments_error?

        json = JSON.generate(tool_call.arguments || {})
        body, cut = clip(json)
        cut ? "#{body} (#{bytes(json)})" : body
      end

      def quote(text)
        return nil if text.nil?

        body, cut = clip(text)
        cut ? %("#{body}" (#{bytes(text)})) : %("#{body}")
      end

      def trim(text) = clip(text).first

      # Invalid bytes degrade to replacement characters instead of raising
      # out of a log line: scrub repairs a string invalid in its own
      # encoding (encode alone skips same-encoding validation), then encode
      # converts binary. The size suffix reports the original payload.
      def clip(text)
        flat = text.to_s.scrub.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
                   .gsub(/\s+/, " ").strip
        return [flat, false] unless @truncate && flat.length > @truncate

        ["#{flat[0, @truncate].rstrip}...", true]
      end

      def clock(duration)
        return nil unless duration

        duration < 1 ? "#{(duration * 1000).round}ms" : "#{duration.round(1)}s"
      end

      def bytes(text)
        size = text.to_s.bytesize
        return "#{size}B" if size < 1024

        size < 1_048_576 ? format("%.1fKB", size / 1024.0) : format("%.1fMB", size / 1_048_576.0)
      end

      def count(number, noun) = "#{number} #{number == 1 ? noun : "#{noun}s"}"

      def presence(text) = text.empty? ? nil : text

      def paint(text, color) = @color ? "\e[#{COLORS.fetch(color)}m#{text}\e[0m" : text

      def write(line, level: :info)
        return if @warned

        level = @level if level == :info
        @logger.public_send(level, "#{@tag} #{line}")
      rescue StandardError => e
        quiet(e)
      end

      def quiet(error)
        return if @warned

        @warned = true
        warn "mistri: logging sink failed (#{error.class}: #{error.message}); " \
             "logging disabled for this run"
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
