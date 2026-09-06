# frozen_string_literal: true

require "digest"
require "json"

module CompactionEval
  # One thing the resumed agent must still know: the words that carried it
  # into the session, where they landed, and the question that checks it
  # survived compaction. A change supersedes an earlier fact of the same key;
  # the latest value is the one every probe and continuation expects.
  class Fact < Data.define(:key, :value, :text, :at, :carrier, :probe, :answer, :match,
                           :supersedes)
    CARRIERS = %i[user assistant tool tool_deep].freeze
    MATCHES = %i[contains exact yes_no].freeze

    def initialize(key:, value:, text:, at:, probe:, carrier: :user, answer: nil, match: :contains,
                   supersedes: nil)
      raise ArgumentError, "unknown carrier #{carrier.inspect}" unless CARRIERS.include?(carrier)
      raise ArgumentError, "unknown match #{match.inspect}" unless MATCHES.include?(match)
      raise ArgumentError, "at must be within 0..0.9" unless (0..0.9).cover?(at)

      super(key: key.to_sym, value: value, text: format(text, value: value), at: at,
            carrier: carrier, probe: probe, answer: answer || value, match: match,
            supersedes: supersedes&.to_sym)
    end

    def change? = !supersedes.nil?
  end

  # A question asked from the compacted context, with the answer it must
  # contain and the fact it checks.
  Probe = Data.define(:key, :carrier, :segment, :question, :answer, :match, :changed)

  # The task the agent must still be able to do: one tool call whose
  # arguments are graded against the latest values of the facts.
  Continuation = Data.define(:prompt, :tool, :description, :schema, :expected)

  # A scenario: one team's work as facts, filler, and the task that proves the
  # agent can still finish it.
  class Scenario
    # Collects the facts of one stretch of the session; later segments arrive
    # after a checkpoint already exists.
    class Segment
      attr_reader :facts

      def initialize
        @facts = []
      end

      def fact(key, value, **)
        @facts << Fact.new(key: key, value: value, **)
      end

      def change(key, value, **)
        ordinal = @facts.count { |fact| fact.supersedes == key.to_sym } + 2
        @facts << Fact.new(key: :"#{key}_v#{ordinal}", value: value, supersedes: key, probe: nil,
                           **)
      end
    end

    attr_reader :name, :summary, :segments

    class << self
      def define(name, summary:, &)
        registry[name] = build(name, summary: summary, &)
      end

      # A scenario that is validated but not registered, for one-off use.
      def build(name, summary:, &)
        scenario = new(name, summary)
        scenario.instance_eval(&)
        scenario.validate!
        scenario
      end

      def [](name) = registry.fetch(name) { raise ArgumentError, "unknown scenario #{name}" }

      def names = registry.keys.sort

      private

      def registry = @registry ||= {}
    end

    def initialize(name, summary)
      @name = name
      @summary = summary
      @segments = []
    end

    def segment(&)
      built = Segment.new
      built.instance_eval(&)
      @segments << built.facts
    end

    # With arguments, declares the task the agent must still be able to do;
    # without, reads it.
    def continuation(**spec)
      @continuation = Continuation.new(**spec) unless spec.empty?
      @continuation
    end

    # With a block, declares how one filler turn renders: { ask:, doing:,
    # tool:, arguments:, log: ->(chars) { ... }, done: } for a turn index and
    # a seeded Random. Without, reads it.
    def filler(&block)
      @filler = block if block
      @filler
    end

    def facts(through: segments.length - 1) = segments[0..through].flatten

    # Anything that changes the experiment invalidates every baseline built on
    # it: the facts and where they sit by segment, the continuation contract,
    # and the whole workload the builder produces for a size, every segment
    # with full payloads (tool names and arguments included) at a fixed seed,
    # so a filler or builder change shows up too. Rows carry this so compare
    # can tell.
    def digest(size: "S")
      @digests ||= {}
      @digests[size] ||= begin
        builder = Builder.new(self, size: size, seed: 1)
        session = builder.build
        (1...segments.length).each { |index| builder.append_segment(session, index) }
        fixture = session.entries.map { |entry| entry.except("at") }
        source = { segments: segments.map { |facts| facts.map(&:to_h) },
                   continuation: [continuation.prompt, continuation.tool,
                                  Mistri::Schema.build(&continuation.schema),
                                  continuation.expected.call(latest)],
                   fixture: fixture }
        Digest::SHA256.hexdigest(JSON.generate(source))[0, 12]
      end
    end

    # Every base fact yields one probe expecting the latest value of its
    # chain; a change with its own question yields one more.
    def probes(through: segments.length - 1)
      all = facts(through: through)
      base = all.reject(&:change?).map do |fact|
        chain = all.select { |other| other.supersedes == fact.key }
        Probe.new(key: fact.key, carrier: fact.carrier, segment: segment_of(fact),
                  question: fact.probe, answer: chain.last ? chain.last.value : fact.answer,
                  match: fact.match, changed: chain.any?)
      end
      extra = all.select { |fact| fact.change? && fact.probe }.map do |fact|
        Probe.new(key: fact.key, carrier: fact.carrier, segment: segment_of(fact),
                  question: fact.probe, answer: fact.answer, match: fact.match, changed: true)
      end
      base + extra
    end

    # Base key to its latest value, what the continuation must act on.
    def latest(through: segments.length - 1)
      all = facts(through: through)
      all.reject(&:change?).to_h do |fact|
        chain = all.select { |other| other.supersedes == fact.key }
        [fact.key, chain.last ? chain.last.value : fact.value]
      end
    end

    def validate!
      raise ArgumentError, "#{name} needs at least one segment" if segments.empty?
      raise ArgumentError, "#{name} needs a filler" unless filler
      raise ArgumentError, "#{name} needs a continuation" unless continuation

      keys = facts.map(&:key)
      duplicates = keys.tally.select { |_, count| count > 1 }.keys
      raise ArgumentError, "#{name} repeats fact keys #{duplicates.inspect}" if duplicates.any?

      facts.select(&:change?).each do |change|
        next if keys.include?(change.supersedes)

        raise ArgumentError, "#{name}: #{change.key} supersedes unknown #{change.supersedes}"
      end
    end

    private

    def segment_of(fact) = segments.index { |facts| facts.include?(fact) }
  end

  # Log-like filler that reads as real output and never repeats a fact.
  module Noise
    module_function

    def lines(rng, chars, &line)
      out = +""
      index = 0
      while out.length < chars
        out << line.call(index, rng) << "\n"
        index += 1
      end
      out[0, chars]
    end

    def stamp(rng)
      format("2026-09-05T%<hour>02d:%<minute>02d:%<second>02dZ",
             hour: rng.rand(8..18), minute: rng.rand(60), second: rng.rand(60))
    end
  end
end
