# frozen_string_literal: true

require "json"

module Mistri
  # When a session compacts, and how much of it survives. Compaction is
  # client-side and provider-agnostic: the session's own provider writes a
  # visible summary, so a host can always show the user exactly what the
  # model still remembers.
  #
  # The trigger measures real token accounting, not guesses: the last healthy
  # turn's reported usage, plus an estimate by a rule measured on each
  # provider's own counts for whatever came after it.
  class Compaction
    DEFAULT_RESERVE = 16_384
    DEFAULT_KEEP_RECENT = 20_000
    DEFAULT_MAX_TOKENS = 16_384
    # Automatic compaction stops retrying after this many automatic failures
    # in a row: a failure the configuration makes predictable must not bill a
    # full-context request every turn.
    AUTOMATIC_ATTEMPTS = 3
    OUTPUT_SAFETY = 4_096
    IMAGE_TOKENS = 1_200
    # For a provider the rule below was not measured on.
    CHARS_PER_TOKEN = 4.0
    # The characters a token holds, measured on each provider's own counts,
    # for letters and spaces, for digits, and for everything else. The kind of
    # content moves the figure more than the provider does.
    CLASS_CHARS_PER_TOKEN = { anthropic: [3.2, 1.6, 1.0], openai: [5.0, 1.2, 1.75],
                              gemini: [5.3, 0.9, 1.05] }.freeze
    # The lowest estimate measured was half of the provider's count.
    ESTIMATE_SPREAD = 2

    # How full the context is, and how many of those tokens are an estimate
    # and not the provider's own count.
    Level = Data.define(:tokens, :estimated) do
      def reported = tokens - estimated
    end

    SUMMARY_PREFACE = "The earlier part of this conversation was compacted. Another model " \
                      "wrote the handoff summary below from those earlier messages; the " \
                      "messages after it are the most recent turns, kept intact. Build on the " \
                      "work already done, do not repeat it, and treat the user's most recent " \
                      "request as the current instruction."

    # For a summary that stands after the turns it leaves, as OpenAI asks of
    # one the caller wrote.
    SUMMARY_PREFACE_AFTER = "The part of this conversation before the messages above was " \
                            "compacted. Another model wrote the handoff summary below from " \
                            "those earlier messages; the messages above are the most recent " \
                            "turns, kept intact. Build on the work already done, do not repeat " \
                            "it, and treat the user's most recent request as the current " \
                            "instruction."

    attr_reader :reserve, :keep_recent, :window, :instructions, :max_tokens, :fallback, :threshold,
                :native

    # window overrides the model catalog's context window (required for
    # models the catalog does not know). A nil reserve selects automatic
    # headroom; a number is explicit host policy. instructions add a
    # host-specific focus to the summary prompt. max_tokens bounds the
    # summary request's output: the summary is the compactor's own request
    # and never inherits the limit a host set for its chat replies. fallback
    # names a second summarizer, a provider or a model id, that gets one try
    # when the session's provider cannot write a usable summary; the host
    # chooses it, so a refusal never changes models silently. threshold is
    # the level where a compaction starts: an Integer of tokens, or a Float
    # for that share of the window. The reserve stays under it as the net.
    # native lets the provider write the summary where it can, which keeps
    # the thinking of the kept turns; false asks for the gem's own summary.
    def initialize(reserve: nil, keep_recent: DEFAULT_KEEP_RECENT, window: nil, instructions: nil,
                   max_tokens: DEFAULT_MAX_TOKENS, fallback: nil, threshold: nil, native: true)
      unless max_tokens.is_a?(Integer) && max_tokens.positive?
        raise ArgumentError, "max_tokens must be a positive Integer"
      end
      unless threshold.nil? || tokens?(threshold) || share?(threshold)
        raise ArgumentError, "threshold must be a positive Integer of tokens or a Float " \
                             "share of the window, above 0 and at most 1"
      end

      @automatic_reserve = reserve.nil?
      @reserve = reserve || DEFAULT_RESERVE
      @keep_recent = keep_recent
      @window = window
      @instructions = instructions
      @max_tokens = max_tokens
      @fallback = summarizer(fallback)
      @threshold = threshold
      @native = native
    end

    def automatic_reserve? = @automatic_reserve

    # The level in tokens above which a compaction is due: the threshold a
    # host set, and never more than the window less the reserve. Automatic
    # headroom fits output that shares the context window, plus estimation
    # and framing slack. An explicit reserve remains host policy. With no
    # window and no threshold in tokens there is none, and nothing triggers.
    def threshold_tokens(window, max_output: nil)
      own = share?(threshold) ? window && (window * threshold).floor : threshold
      [own, ceiling(window, max_output:)].compact.min
    end

    # The most tokens a request may hold in a window: the window less the
    # reserve. Nil with no window.
    def ceiling(window, max_output: nil)
      window && (window - effective_reserve(max_output))
    end

    def needed?(tokens, window, max_output: nil)
      limit = threshold_tokens(window, max_output:)
      limit ? tokens > limit : false
    end

    # The tokens of recent turns a compaction keeps: keep_recent, and never
    # more than half of what the threshold leaves above the fixed part of a
    # request, its system prompt and tools. So about half of that room is
    # free for the turns that follow.
    def keep_within(threshold, fixed)
      return keep_recent unless threshold

      ((threshold - fixed) / 2).clamp(0, keep_recent)
    end

    private

    def tokens?(value) = value.is_a?(Integer) && value.positive?

    def share?(value) = value.is_a?(Float) && value.positive? && value <= 1

    # A model id resolves at construction, so a missing key fails where the
    # setting is written rather than in the middle of a run.
    def summarizer(fallback)
      return fallback if fallback.nil?
      return fallback if fallback.respond_to?(:stream) && fallback.respond_to?(:model)
      return Mistri.provider(fallback) if fallback.is_a?(String)

      raise ArgumentError, "fallback must be a provider or a model id"
    end

    def effective_reserve(max_output)
      return reserve unless automatic_reserve?

      max_output ? [max_output + OUTPUT_SAFETY, reserve].max : reserve
    end

    class << self
      def context_tokens(messages, **)
        level(messages, **).tokens
      end

      # The level of a replay: the last healthy turn's reported tokens
      # (prompt, cache, and output all sit in context next turn) plus an
      # estimate of every message after it. counted is the provider's count of
      # what a compaction left, which stands in until a turn reports. provider
      # names whose rule estimates, when it is not the one that wrote the
      # latest turn.
      def level(messages, usage_from: 0, counted: nil, provider: nil)
        index = (usage_from...messages.length).reverse_each.find do |position|
          reported(messages[position])
        end
        base, from = if index then [reported(messages[index]).context_tokens, index + 1]
                     elsif counted then [counted, usage_from]
                     else [0, 0]
                     end
        provider ||= latest_provider(messages)
        estimated = messages.drop(from).sum { |message| estimate(message, provider) }
        Level.new(tokens: base + estimated, estimated:)
      end

      # The tokens that each message and all after it hold in the context.
      # The prompt a turn reported is the size of everything before that
      # turn, so a tail is the level less that prompt. Only a message with no
      # reported turn at or after it is estimated to the end.
      def tail_tokens(messages, usage_from: 0, counted: nil, provider: nil)
        provider ||= latest_provider(messages)
        total = context_tokens(messages, usage_from:, counted:, provider:)
        before = nil
        estimated = 0
        tails = Array.new(messages.length)
        (messages.length - 1).downto(0) do |position|
          message = messages[position]
          usage = reported(message) if position >= usage_from
          if usage then before = usage.context_tokens - usage.output
          elsif before then before = [before - estimate(message, provider), 0].max
          else estimated += estimate(message, provider)
          end
          tails[position] = before ? total - before : estimated
        end
        tails
      end

      # The provider's own count of the input tokens of a request. Nil when
      # the provider has none or the count fails: an estimate stands then.
      def count(provider, request)
        provider.count_tokens(**request) if provider.respond_to?(:count_tokens)
      rescue Error
        nil
      end

      def latest_provider(messages)
        messages.reverse_each.find { |message| message.assistant? && message.provider }&.provider
      end

      def estimate(message, provider = nil)
        rule = CLASS_CHARS_PER_TOKEN[provider]
        message.content.sum { |block| tokens_of(block, rule) }.ceil
      end

      private

      def reported(message)
        return nil unless message.assistant? && message.usage
        return nil if %i[aborted error].include?(message.stop_reason)

        message.usage if message.usage.context_tokens.positive?
      end

      def tokens_of(block, rule)
        case block
        when Content::Image then IMAGE_TOKENS
        when Content::Text then tokens_in(block.text, rule)
        when Content::Thinking then tokens_in(block.thinking, rule)
        when Content::Compaction then tokens_in(block.text.to_s, rule)
        else tokens_in("#{block.name}#{JSON.generate(block.arguments)}", rule)
        end
      end

      def tokens_in(text, rule)
        return text.length / CHARS_PER_TOKEN unless rule

        words, digits, other = rule
        spelled = text.count("a-zA-Z \n\t\r")
        figures = text.count("0-9")
        (spelled / words) + (figures / digits) + ((text.length - spelled - figures) / other)
      end
    end
  end
end
