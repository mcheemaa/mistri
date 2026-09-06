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

    attr_reader :rows

    # on_row receives every finished row as it lands, so a long paid run
    # keeps what it measured even if a later cell fails.
    def initialize(models:, scenarios:, sizes:, repeat: 1, seed: 1, folds: false, baselines: false,
                   provider_for: ->(model) { Mistri.provider(model) }, settings: {}, io: $stderr,
                   on_row: nil)
      @models = models
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

    def compacted_row(model, scenario, size, rep)
      builder = Builder.new(scenario, size: size, seed: @seed + rep)
      session = builder.build
      compactions = [compact(session, builder, model)]
      last_segment = 0
      if @folds
        (1...scenario.segments.length).each do |index|
          builder.append_segment(session, index)
          compactions << compact(session, builder, model)
          last_segment = index
        end
      end
      row = base_row(model, scenario, size, rep, :compacted)
      row[:folds] = compactions.length
      row[:compactions] = compactions
      return row.merge(skipped: "compaction rejected") unless compactions.all? { |c| c[:accepted] }

      row.merge(measure(model, scenario, session, last_segment))
    end

    def baseline_row(model, scenario, size, mode)
      builder = Builder.new(scenario, size: size, seed: @seed)
      session = builder.build
      session = builder.tail_session(session) if mode == :tail
      base_row(model, scenario, size, 0, mode).merge(measure(model, scenario, session, 0))
    end

    def base_row(model, scenario, size, rep, mode)
      { model: model, scenario: scenario.name, size: size, rep: rep, mode: mode.to_s,
        seed: @seed + rep, git_sha: self.class.git_sha, prompt_digest: self.class.prompt_digest,
        at: Time.now.utc.iso8601 }
    end

    def compact(session, builder, model)
      settings = Mistri::Compaction.new(keep_recent: Builder::KEEP_RECENT, **@settings)
      started = clock
      result = Mistri::Compactor.call(session: session, provider: provider(model),
                                      settings: settings)
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
      { probes: probes, probe_accuracy: share(probes, :pass),
        accuracy_by_carrier: by(probes, :carrier), accuracy_by_segment: by(probes, :segment),
        changed_accuracy: share(probes.select { |p| p[:changed] }, :pass),
        literal_recall: (share(probes, :literal) if summary), continuation: continuation,
        cost: probes.sum { |p| p[:cost] || 0.0 } + (continuation[:cost] || 0.0),
        unpriced: probes.count { |p| p[:cost].nil? } + (continuation[:cost].nil? ? 1 : 0) }
    end

    def grade(probe, reply)
      text = reply.text.to_s
      { key: probe.key, carrier: probe.carrier, segment: probe.segment, changed: probe.changed,
        question: probe.question, answer: probe.answer, reply: text[0, 300],
        pass: reply.stop_reason != :error && Grader.pass?(text, probe.answer, probe.match),
        stop_reason: reply.stop_reason, error: reply.error_message, cost: cost_of(reply.usage) }
    end

    def ask(model, messages, question)
      with_retry do
        provider(model).stream(messages: messages + [Mistri::Message.user(question)],
                               system: PROBE_SYSTEM, **PROBE_OVERRIDES)
      end
    end

    def continue(model, session, scenario, latest)
      spec = scenario.continuation
      recorded = nil
      tool = Mistri::Tool.define(spec.tool, spec.description, schema: spec.schema,
                                                              ends_turn: true) do |args|
        recorded = args
        "recorded"
      end
      agent = Mistri::Agent.new(provider: provider(model), session: session, tools: [tool],
                                system: CONTINUE_SYSTEM, compaction: false)
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

        sleep(3 * (attempt + 1))
      end
      reply
    end

    def share(items, key)
      return nil if items.empty?

      (items.count { |item| item[key] }.to_f / items.length).round(3)
    end

    def by(probes, key)
      probes.group_by { |probe| probe[key] }
            .to_h { |group, items| [group.to_s, share(items, :pass)] }
    end

    def cost_of(usage)
      return nil unless usage&.cost&.known?

      usage.cost.total.round(6)
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    class << self
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
