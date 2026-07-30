# frozen_string_literal: true

require "json"

module Mistri
  module Sinks
    # Renders the event stream as one log line per meaningful beat, so a
    # log tells each run's whole story: which tools ran with which
    # arguments, how long each took, what every turn cost, and how the run
    # ended. Deltas never log (whole blocks do).
    #
    # Assigning Mistri.logger turns this on for every run in one line:
    #
    #   Mistri.logger = Rails.logger
    #   Mistri.logger = Mistri::Sinks::Logger.new(logger, color: true)
    #
    # Payloads (inputs, text, thinking, arguments, results, reports) log in
    # full by default; content: false keeps the same story with metadata
    # only, for logs whose payloads must stay out. level: floors the
    # ordinary lines (warnings and errors keep their own levels).
    #
    # Sinks the Agent builds through for_session skip origin-tagged events,
    # because every agent logs its own events under its own tag: exactly
    # once, however deep the nesting and whichever process runs it. A sink
    # composed directly (agent.run(input, &sink)) is the only logger its
    # run has, so it renders forwarded child events instead, origin first;
    # framing (run, done) still comes only from the Agent.
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
      QUIET = %i[text_end thinking_end tool_started done approval_needed
                 compacting compaction subagent_report].to_h { |type| [type, true] }.freeze
      COLORS = { bold: "1", dim: "2", red: "31", green: "32", yellow: "33" }.freeze
      LEVELS = %i[debug info warn error].freeze
      # C0 and C1 controls, DEL, Unicode line and paragraph separators, and
      # bidi embedding controls: everything that could steer a terminal or
      # forge a line while staying invisible.
      HIDDEN = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/
      HEAD = 4096
      private_constant :SKIPPED, :LINES, :QUIET, :COLORS, :LEVELS, :HIDDEN, :HEAD

      # truncate bounds every rendered value (nil for full payloads).
      # session is the line tag, verbatim, so concurrent runs stay
      # distinguishable. Options are validated here so a bad configuration
      # fails at assignment time, not silently at run time.
      def initialize(logger, session: nil, truncate: 200, color: false, level: :info,
                     content: true, forwarded: :render)
        raise ArgumentError, "level must be one of #{LEVELS.join(", ")}" unless
          LEVELS.include?(level)
        unless truncate.nil? || (truncate.is_a?(Integer) && truncate.positive?)
          raise ArgumentError, "truncate must be a positive Integer or nil"
        end
        raise ArgumentError, "forwarded must be :render or :skip" unless
          %i[render skip].include?(forwarded)

        @logger = logger
        @truncate = truncate
        @color = color
        @level = level
        @content = content
        @forwarded = forwarded
        @session = session && field(session, limit: 48)
        @turns = 0
        @started = now
        @warned = false
        @tag = paint(@session ? "[mistri #{@session}]" : "[mistri]", :dim)
      end

      # A fresh sink for one run: same logger and options, this run's tag
      # (a sub-agent's label, or the session id), its own turn count and
      # clock. Runs framed this way skip forwarded events, because each
      # agent in the tree logs its own.
      def for_session(id, label: nil)
        self.class.new(@logger, session: label || id.to_s[0, 8], truncate: @truncate,
                                color: @color, level: @level, content: @content, forwarded: :skip)
      end

      # The global hookup: builds this run's sink from Mistri.logger, or
      # nil. Contained, so a broken assignment costs the log, never the run.
      def self.attach(id, label: nil)
        configured = Mistri.logger
        return nil unless configured

        sink = configured.respond_to?(:for_session) ? configured : new(configured)
        sink.for_session(id, label: label)
      rescue StandardError => e
        warn "mistri: logging sink construction failed (#{e.class}: #{e.message}); run not logged"
        nil
      end

      def call(event)
        return if @warned

        return if event.origin && (@forwarded == :skip)
        return if SKIPPED[event.type]
        return if QUIET[event.type] && !floor_enabled?

        handler = LINES[event.type]
        prefix = event.origin ? "#{field(event.origin)} " : ""
        # Future event types degrade to a greppable line, never to silence.
        line = handler ? send(handler, event) : "#{event.type} #{trim(event.content)}".rstrip
        write("#{prefix}#{line.first}", level: line.last) if line.is_a?(Array)
        write("#{prefix}#{line}") if line.is_a?(String)
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
        return unless floor_enabled?

        ask = input && @content ? %( "#{trim(input)}") : ""
        write("#{paint(verb, :bold)}#{ask} (#{field(model)}, #{count(tool_count, "tool")})")
      rescue StandardError => e
        quiet(e)
      end

      def run_finished(result)
        status, level = status_of(result)
        return if level == :info && !floor_enabled?

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
        body = body_of(event.content)
        body.empty? ? nil : "text #{body}"
      end

      def thinking_line(event)
        body = body_of(event.content)
        body.empty? ? nil : "thinking #{body}"
      end

      def tool_line(event)
        "tool #{title(event.tool_call)} #{arguments(event.tool_call)}".rstrip
      end

      def tool_result_line(event)
        verdict = event.tool_error? ? paint("FAILED", :red) : "ok"
        parts = ["tool #{title(event.tool_call)} #{verdict}", clock(event.duration),
                 presence(body_of(event.content))]
        [parts.compact.join(" "), event.tool_error? ? :warn : :info]
      end

      def turn_line(event)
        @turns += 1
        "turn #{@turns} done #{event.reason}#{tokens(event.message&.usage)}"
      end

      # :error also carries expected stops, which log calmly; only real
      # failures alarm. A budget stop is synthetic (no provider call), so
      # it alone does not count as a turn.
      def error_line(event)
        case event.reason
        when StopReason::BUDGET then ["stopped on budget", :warn]
        when StopReason::ABORTED
          @turns += 1
          "aborted"
        else
          @turns += 1
          detail = [event.reason, presence(trim(event.error_message))].compact.join(": ")
          ["#{paint("error", :red)} #{detail}", :error]
        end
      end

      def retry_line(event)
        wait = event.delay ? " in #{event.delay.round(1)}s" : ""
        ["#{paint("retry", :yellow)} #{event.attempt}/#{event.max_attempts}#{wait}: " \
         "#{trim(event.content)}", :warn]
      end

      # The full call id rides the line: Session#approve takes exactly that
      # id, and the short pairing suffix is not it.
      def approval_line(event)
        call = event.tool_call
        parts = ["approval needed #{title(call)}", presence(arguments(call)),
                 "id #{field(call.id, limit: 128)}"]
        parts.compact.join(" ")
      end

      def compacting_line(_event) = "compacting"

      def compaction_line(event) = "compacted #{body_of(event.content)}"

      def report_line(event)
        "worker #{field(event.agent)} (#{field(event.session_id.to_s[0, 8], limit: 16)}) " \
        "#{event.status} #{body_of(event.content)}".rstrip
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

        base = ", #{prompt(usage)} / #{usage.output} out"
        cost = usage.cost
        cost&.known? ? base + format(", $%.4f", cost.total) : base
      end

      def tokens(usage)
        usage ? " (#{prompt(usage)} / #{usage.output} out)" : ""
      end

      # Cache traffic is real prompt volume; input alone under-reports it.
      def prompt(usage)
        cached = usage.cache_read + usage.cache_write
        return "#{usage.input} in" unless cached.positive?

        "#{usage.input + cached} in (#{cached} cached)"
      end

      # A short call id makes concurrent same-name calls pairable.
      def title(tool_call)
        return paint("?", :green) unless tool_call

        name = paint(field(tool_call.name), :green)
        id = field(tool_call.id, limit: 128)
        ref = id.length > 4 ? id[-4, 4] : id
        ref.empty? ? name : "#{name}##{ref}"
      end

      def arguments(tool_call)
        return "[#{trim(tool_call.arguments_error)}]" if tool_call.arguments_error?
        return "" unless @content

        rendered = +""
        preview(tool_call.arguments || {}, rendered)
        trim(rendered)
      end

      # A bounded JSON preview: rendering stops once the budget is spent,
      # so a payload near the 8 MiB argument ceiling never materializes as
      # a whole serialized string on the emission path.
      def preview(value, out)
        return out << "..." if @truncate && out.length > @truncate

        case value
        when Hash
          walk(value, out, "{", "}") do |(key, item)|
            out << JSON.generate(key.to_s) << ":"
            preview(item, out)
          end
        when Array
          walk(value, out, "[", "]") { |item| preview(item, out) }
        when String
          out << JSON.generate(@truncate ? value[0, @truncate] : value)
        else
          out << JSON.generate(value)
        end
      end

      def walk(items, out, open, close)
        out << open
        items.each_with_index do |item, index|
          break if @truncate && out.length > @truncate && index.positive?

          out << "," if index.positive?
          yield(item)
        end
        out << close
      end

      # content: false keeps the beat and the volume, never the words.
      def body_of(text)
        return "" if text.nil? || text.to_s.strip.empty?
        return "(#{bytes(text)})" unless @content

        quote(text)
      end

      def quote(text)
        body, cut = clip(text)
        cut ? %("#{body}" (#{bytes(text)})) : %("#{body}")
      end

      def trim(text) = clip(text).first

      # Structural scalars (tags, names, ids, labels) are bounded and
      # stripped of hidden bytes before they join a line, so untrusted
      # values cannot forge lines or steer a terminal.
      def field(value, limit: 64)
        clip(value, limit: limit).first
      end

      # String work per line stays bounded: only a head of the payload is
      # normalized, never all of it. scrub repairs invalid bytes (encode
      # alone skips same-encoding validation), encode converts binary, and
      # hidden bytes become visible escapes. The size suffix reports the
      # whole payload.
      def clip(text, limit: @truncate)
        raw = text.to_s
        head = limit ? raw[0, [(limit * 2) + 1, HEAD].max] : raw
        flat = head.scrub.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
                   .gsub(/\s+/, " ").strip
                   .gsub(HIDDEN) { |hidden| format("\\u%04x", hidden.ord) }
        cut = limit && (flat.length > limit || head.bytesize < raw.bytesize)
        return [flat, false] unless cut

        ["#{flat[0, limit].rstrip}...", true]
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

      def presence(text) = text.nil? || text.empty? ? nil : text

      def paint(text, color) = @color ? "\e[#{COLORS.fetch(color)}m#{text}\e[0m" : text

      # Formatting is skipped entirely when the floor level is disabled on
      # the host logger; warnings and errors always go through.
      def floor_enabled?
        query = :"#{@level}?"
        !@logger.respond_to?(query) || @logger.public_send(query)
      rescue StandardError
        true
      end

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
