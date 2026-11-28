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

    SUMMARY_PREFACE = "The earlier part of this conversation was compacted. Another model " \
                      "wrote the handoff summary below from those earlier messages; the " \
                      "messages after it are the most recent turns, kept intact. Build on the " \
                      "work already done, do not repeat it, and treat the user's most recent " \
                      "request as the current instruction."

    attr_reader :reserve, :keep_recent, :window, :instructions, :max_tokens, :fallback

    # window overrides the model catalog's context window (required for
    # models the catalog does not know). A nil reserve selects automatic
    # headroom; a number is explicit host policy. instructions add a
    # host-specific focus to the summary prompt. max_tokens bounds the
    # summary request's output: the summary is the compactor's own request
    # and never inherits the limit a host set for its chat replies. fallback
    # names a second summarizer, a provider or a model id, that gets one try
    # when the session's provider cannot write a usable summary; the host
    # chooses it, so a refusal never changes models silently.
    def initialize(reserve: nil, keep_recent: DEFAULT_KEEP_RECENT, window: nil,
                   instructions: nil, max_tokens: DEFAULT_MAX_TOKENS, fallback: nil)
      unless max_tokens.is_a?(Integer) && max_tokens.positive?
        raise ArgumentError, "max_tokens must be a positive Integer"
      end

      @automatic_reserve = reserve.nil?
      @reserve = reserve || DEFAULT_RESERVE
      @keep_recent = keep_recent
      @window = window
      @instructions = instructions
      @max_tokens = max_tokens
      @fallback = summarizer(fallback)
    end

    def automatic_reserve? = @automatic_reserve

    # Automatic headroom fits output that shares the context window, plus
    # estimation and framing slack. An explicit reserve remains host policy.
    # An unknown window never triggers.
    def needed?(tokens, window, max_output: nil)
      window ? tokens > window - effective_reserve(max_output) : false
    end

    private

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
      # Context size for a replay: the last healthy turn's reported tokens
      # (prompt, cache, and output all sit in context next turn) plus an
      # estimate of every message after it.
      def context_tokens(messages, usage_from: 0)
        index = (usage_from...messages.length).reverse_each.find do |position|
          reported(messages[position])
        end
        base = index ? reported(messages[index]) : 0
        provider = latest_provider(messages)
        messages.drop(index ? index + 1 : 0).sum(base) { |message| estimate(message, provider) }
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

        total = message.usage.context_tokens
        total.positive? ? total : nil
      end

      def tokens_of(block, rule)
        case block
        when Content::Image then IMAGE_TOKENS
        when Content::Text then tokens_in(block.text, rule)
        when Content::Thinking then tokens_in(block.thinking, rule)
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
