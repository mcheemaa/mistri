# frozen_string_literal: true

require "digest"
require "json"
require "time"

module CompactionEval
  # Runs the matrix: for each model, scenario, and size it builds a session,
  # compacts it with the real Compactor, then measures what the same model
  # can still answer and do from the compacted context. Baselines bound the
  # result: the full history above, the kept tail alone below.
  class Runner
    PROBE_SYSTEM = "You are continuing this work. Answer from the conversation so far. Be exact " \
                   "and brief: when the answer is a value, reply with the value only."
    CONTINUE_SYSTEM = "You are continuing this work. The values were agreed earlier in the " \
                      "conversation; do not ask for confirmation. Call the tool exactly once, " \
                      "now, with those exact values."
    PROBE_OVERRIDES = { max_tokens: 2_000, thinking: nil, reasoning: nil }.freeze
    TRANSIENT = /rate|overload|timeout|timed out|connection|reset|50[023]|529/i
    JUDGE_SYSTEM = "You audit a summary against the transcript it was written from. List every " \
                   "claim in the summary that the transcript does not support: an invented " \
                   "value, a changed number, a wrong attribution, a fact that is not there. " \
                   "Quote each claim as the summary states it. Then rate resumability from 1 to " \
                   "5: could an engineer with only this summary and the last few turns resume " \
                   "the work without asking questions? 5 means nothing needed is missing, 3 " \
                   "means the shape is there but a key value is not, 1 means they would start " \
                   "over."
    JUDGE_SCHEMA = {
      type: "object",
      properties: {
        "unsupported_claims" => { type: "array",
                                  items: { type: "object",
                                           properties: { "claim" => { type: "string" },
                                                         "reason" => { type: "string" } },
                                           required: %w[claim reason] } },
        "resumability" => { type: "integer", enum: [1, 2, 3, 4, 5] },
        "rationale" => { type: "string" }
      },
      required: %w[unsupported_claims resumability rationale]
    }.freeze
    # The judge never grades its own family's summary: Astra judges everyone,
    # Sol judges Astra.
    DEFAULT_JUDGE = "gpt-6-astra"
    JUDGE_FOR_ASTRA = "gpt-5.6-sol"
    # One call and a correction or two; a model that keeps sending invalid
    # arguments must not loop on a paid run.
    CONTINUATION_TURNS = 4

    # Keeps what a summarizer was shown, so the judge audits the summary
    # against the transcript it was written from and nothing else.
    class Recording
      attr_reader :transcripts

      def initialize(provider)
        @provider = provider
        @transcripts = []
      end

      def model = @provider.model

      def stream(messages:, system: nil, **, &)
        if system == Mistri::Compactor::SUMMARIZER_SYSTEM
          @transcripts << messages.last.text[%r{<conversation>.*</conversation>}m].to_s
        end
        @provider.stream(messages: messages, system: system, **, &)
      end
    end

    attr_reader :rows

    # on_row receives every finished row as it lands, so a long paid run
    # keeps what it measured even if a later cell fails. reader names one
    # model to answer every probe instead of the summarizer itself; judge is
    # a model id, :auto for the cross-family default, or nil for no judge.
    def initialize(models:, scenarios:, sizes:, repeat: 1, seed: 1, folds: false, baselines: false,
                   provider_for: ->(model) { Mistri.provider(model) }, settings: {}, io: $stderr,
                   on_row: nil, reader: nil, judge: :auto, pause: 3)
      @models = models
      @pause = pause
      @scenarios = scenarios.map { |name| name.is_a?(Scenario) ? name : Scenario[name] }
      @sizes = sizes
      @repeat = repeat
      @seed = seed
      @folds = folds
      @baselines = baselines
      @provider_for = provider_for
      @settings = settings
      @io = io
      @on_row = on_row
      @reader = reader
      @judge = judge
      @providers = {}
      @rows = []
    end

    def run
      @models.each do |model|
        @scenarios.each do |scenario|
          @sizes.each do |size|
            @repeat.times { |rep| record(compacted_row(model, scenario, size, rep)) }
            next unless @baselines

            record(baseline_row(model, scenario, size, :full))
            record(baseline_row(model, scenario, size, :tail))
          end
        end
      end
      rows
    end

    private

    def record(row)
      @rows << row
      @io.puts(Report.line(row))
      @on_row&.call(row)
      row
    end

    def provider(model)
      @providers[model] ||= @provider_for.call(model)
    end

    def reader(model) = provider(@reader || model)

    def judge_for(model)
      return @judge.to_s unless @judge == :auto

      model == DEFAULT_JUDGE ? JUDGE_FOR_ASTRA : DEFAULT_JUDGE
    end

    def compacted_row(model, scenario, size, rep)
      builder = Builder.new(scenario, size: size, seed: @seed + rep)
      session = builder.build
      recording = Recording.new(provider(model))
      compactions = [compact(session, builder, recording)]
      last_segment = 0
      if @folds
        (1...scenario.segments.length).each do |index|
          builder.append_segment(session, index)
          compactions << compact(session, builder, recording)
          last_segment = index
        end
      end
      row = base_row(model, scenario, size, rep, :compacted)
      row[:folds] = compactions.length
      row[:compactions] = compactions
      return row.merge(skipped: "compaction rejected") unless compactions.all? { |c| c[:accepted] }

      measured = row.merge(measure(model, scenario, session, last_segment))
      verdict = judge(model, recording, session)
      return measured unless verdict

      measured.merge(judge: verdict,
                     unpriced: measured[:unpriced] + (verdict[:cost].nil? ? 1 : 0))
    end

    def baseline_row(model, scenario, size, mode)
      builder = Builder.new(scenario, size: size, seed: @seed)
      session = builder.build
      session = builder.tail_session(session) if mode == :tail
      base_row(model, scenario, size, 0, mode).merge(measure(model, scenario, session, 0))
    end

    def base_row(model, scenario, size, rep, mode)
      { model: model, scenario: scenario.name, size: size, rep: rep, mode: mode.to_s,
        seed: @seed + rep, reader: @reader, git_sha: self.class.git_sha,
        prompt_digest: self.class.prompt_digest, scenario_digest: scenario.digest,
        at: Time.now.utc.iso8601 }
    end

    def compact(session, builder, summarizer)
      settings = Mistri::Compaction.new(keep_recent: Builder::KEEP_RECENT, **@settings)
      started = clock
      result = Mistri::Compactor.call(session: session, provider: summarizer, settings: settings)
      raise "nothing to compact: the fixture never crossed a cut" unless result

      kept_from = session.last_compaction.fetch("kept_from")
      { accepted: true, model: session.last_compaction["model"], kept_from: kept_from,
        facts_kept: builder.facts_kept(kept_from), tokens_before: result[:tokens_before],
        tokens_after: result[:tokens_after], output_tokens: result[:usage]&.output,
        summary_tokens: (result[:summary].length / 4.0).round, cost: cost_of(result[:usage]),
        elapsed: (clock - started).round(1), summary: result[:summary] }
    rescue Mistri::CompactionError => e
      { accepted: false, reason: e.message, cost: cost_of(e.usage),
        elapsed: (clock - started).round(1) }
    end

    def measure(model, scenario, session, last_segment)
      probes = scenario.probes(through: last_segment).map do |probe|
        grade(probe, ask(model, session.messages, probe.question))
      end
      summary = session.last_compaction&.fetch("summary", "")
      if summary
        probes.each { |result| result[:literal] = Grader.literal?(summary, result[:answer]) }
      end
      continuation = continue(model, session, scenario, scenario.latest(through: last_segment))
      { probes: probes, continuation: continuation,
        cost: probes.sum { |p| p[:cost] || 0.0 } + (continuation[:cost] || 0.0),
        unpriced: probes.count { |p| p[:cost].nil? } + (continuation[:cost].nil? ? 1 : 0) }
        .merge(self.class.scores(probes, summary))
    end

    def grade(probe, reply)
      text = reply.text.to_s
      { key: probe.key, carrier: probe.carrier, segment: probe.segment, changed: probe.changed,
        question: probe.question, answer: probe.answer, match: probe.match, reply: text[0, 2_000],
        pass: reply.stop_reason != :error && Grader.pass?(text, probe.answer, probe.match),
        stop_reason: reply.stop_reason, error: reply.error_message, cost: cost_of(reply.usage) }
    end

    def ask(model, messages, question)
      with_retry do
        reader(model).stream(messages: messages + [Mistri::Message.user(question)],
                             system: PROBE_SYSTEM, **PROBE_OVERRIDES)
      end
    end

    # The judge sees exactly what the summarizers saw and the final summary,
    # and answers in a schema, so its verdict parses without a regex.
    def judge(model, recording, session)
      return nil unless @judge

      summary = session.last_compaction&.fetch("summary", nil)
      return nil unless summary

      judge_model = judge_for(model)
      prompt = "#{recording.transcripts.join("\n\n")}\n\n<summary>\n#{summary}\n</summary>\n\n" \
               "Audit the summary against the transcript."
      agent = Mistri::Agent.new(provider: provider(judge_model), system: JUDGE_SYSTEM,
                                compaction: false)
      result = agent.task(prompt, schema: JUDGE_SCHEMA)
      claims = Array(result.output&.fetch("unsupported_claims", nil))
      { model: judge_model, claims: claims, unsupported: claims.length,
        resumability: result.output&.fetch("resumability", nil),
        rationale: result.output&.fetch("rationale", nil), status: result.status.to_s,
        cost: cost_of(result.usage) }
    rescue StandardError => e
      { model: judge_model, status: "error: #{e.class}: #{e.message[0, 200]}", cost: nil }
    end

    def continue(model, session, scenario, latest)
      spec = scenario.continuation
      recorded = nil
      tool = Mistri::Tool.define(spec.tool, spec.description, schema: spec.schema,
                                                              ends_turn: true) do |args|
        recorded = args
        "recorded"
      end
      agent = Mistri::Agent.new(provider: reader(model), session: session, tools: [tool],
                                system: CONTINUE_SYSTEM, compaction: false,
                                budget: Mistri::Budget.new(turns: CONTINUATION_TURNS))
      result = agent.run(spec.prompt)
      expected = spec.expected.call(latest)
      matched = expected.select { |key, value| recorded && Grader.same?(recorded[key], value) }.keys
      { success: matched.length == expected.length, called: !recorded.nil?, matched: matched,
        expected: expected, actual: recorded, status: recorded ? result.status : "no tool call",
        cost: cost_of(result.usage) }
    rescue StandardError => e
      { success: false, called: false, matched: [], expected: spec.expected.call(latest),
        actual: nil, status: "error: #{e.class}: #{e.message[0, 200]}", cost: nil }
    end

    def with_retry(attempts: 3)
      reply = nil
      attempts.times do |attempt|
        reply = yield
        break unless reply.stop_reason == :error && reply.error_message.to_s.match?(TRANSIENT)
        break if attempt == attempts - 1

        sleep(@pause * (attempt + 1))
      end
      reply
    end

    def cost_of(usage)
      return nil unless usage&.cost&.known?

      usage.cost.total.round(6)
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    class << self
      # The scores a row carries, computed from its probes so a stored row can
      # be graded again after a grader change without another paid run.
      def scores(probes, summary)
        { probe_accuracy: share(probes, :pass),
          accuracy_by_carrier: by(probes, :carrier), accuracy_by_segment: by(probes, :segment),
          changed_accuracy: share(probes.select { |p| p[:changed] }, :pass),
          literal_recall: (share(probes, :literal) if summary) }
      end

      def regrade(row)
        return row if row[:skipped] || row[:probes].nil?

        summary = row[:compactions]&.last&.dig(:summary)
        probes = row[:probes].map do |probe|
          pass = probe[:stop_reason].to_s != "error" &&
                 Grader.pass?(probe[:reply], probe[:answer], (probe[:match] || :contains).to_sym)
          literal = summary ? Grader.literal?(summary, probe[:answer]) : nil
          probe.merge(pass: pass, literal: literal)
        end
        row.merge(probes: probes, continuation: regrade_continuation(row[:continuation]))
           .merge(scores(probes, summary))
      end

      # A row without the words: scores, verdicts, and costs stay; summaries,
      # replies, questions, claims, and tool arguments go. Safe to commit.
      def distill(row)
        row.merge(
          compactions: Array(row[:compactions]).map { |c| c.except(:summary) },
          probes: Array(row[:probes]).map do |probe|
            probe.slice(:key, :carrier, :segment, :changed, :match, :pass, :literal, :stop_reason)
          end,
          continuation: row[:continuation]&.slice(:success, :called, :matched, :status, :cost),
          judge: row[:judge]&.slice(:model, :unsupported, :resumability, :status, :cost)
        ).compact
      end

      def regrade_continuation(continuation)
        return continuation unless continuation && continuation[:actual]

        expected = continuation[:expected]
        matched = expected.select do |key, value|
          Grader.same?(continuation[:actual][key.to_s] || continuation[:actual][key.to_sym], value)
        end.keys
        continuation.merge(matched: matched, success: matched.length == expected.length)
      end

      def share(items, key)
        return nil if items.empty?

        (items.count { |item| item[key] }.to_f / items.length).round(3)
      end

      def by(probes, key)
        probes.group_by { |probe| probe[key] }
              .to_h { |group, items| [group.to_s, share(items, :pass)] }
      end

      def git_sha
        sha = `git rev-parse --short HEAD 2>/dev/null`.strip
        sha.empty? ? "unknown" : sha
      end

      # Tags a run with the prompt it measured, so a local prompt override can
      # never be mistaken for a baseline.
      def prompt_digest
        text = [Mistri::Compactor::SUMMARIZER_SYSTEM, Mistri::Compactor::CHECKPOINT_PROMPT,
                Mistri::Compactor::UPDATE_PROMPT].join("\n")
        Digest::SHA256.hexdigest(text)[0, 12]
      end
    end
  end
end
