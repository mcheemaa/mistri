# frozen_string_literal: true

module Mistri
  module Providers
    # The Anthropic Messages API, streamed. Defaults target the current model
    # generation: adaptive thinking with summarized display (so thinking
    # streams for the UI), prompt caching on, 32k output headroom.
    #
    # Provider failures fold into the stream as an error turn rather than
    # raising: the loop decides whether to retry, and the host always gets a
    # message back.
    class Anthropic
      VERSION_HEADER = "2023-06-01"
      DEFAULT_THINKING = { type: "adaptive", display: "summarized" }.freeze

      def initialize(api_key:, model: "claude-opus-4-8", origin: "https://api.anthropic.com",
                     max_tokens: nil, thinking: DEFAULT_THINKING, cache: true,
                     **transport_options)
        @api_key = api_key
        @model = model
        @max_tokens = max_tokens
        @thinking = thinking
        @cache = cache
        @transport = Transport.new(origin: origin, **transport_options)
      end

      def stream(messages:, system: nil, tools: [], signal: nil, **overrides, &emit)
        model = overrides.fetch(:model, @model)
        assembler = Anthropic::Assembler.new(model: model)
        body = build_body(model, messages, system, tools, overrides)
        outcome = @transport.stream_post("/v1/messages", body: body, headers: headers,
                                                         signal: signal) do |record|
          assembler.feed(
            record, &emit
          )
        end
        outcome == :aborted ? assembler.abort(&emit) : assembler.finish(&emit)
      rescue Error => e
        assembler.fail_stream(e, &emit)
      end

      def close = @transport.close

      private

      def build_body(model, messages, system, tools, overrides)
        body = {
          model: model,
          max_tokens: max_tokens_for(model, overrides),
          stream: true,
          messages: Serializer.messages(messages, cache: @cache)
        }
        system_blocks = Serializer.system_blocks(system, cache: @cache)
        body[:system] = system_blocks if system_blocks
        body[:tools] = Serializer.tools(tools) if tools.any?
        thinking = overrides.fetch(:thinking, @thinking)
        body[:thinking] = thinking if thinking
        body
      end

      # The API requires max_tokens and bills only actual output, so the right
      # default is the model's own ceiling: full headroom, no silent
      # truncation. An unknown model falls back high on purpose; the loud 400
      # from an older model beats quietly cutting a long answer short.
      def max_tokens_for(model, overrides)
        overrides.fetch(:max_tokens) { @max_tokens || Models.max_output(model) || 32_000 }
      end

      def headers
        { "x-api-key" => @api_key, "anthropic-version" => VERSION_HEADER }
      end
    end
  end
end

require_relative "anthropic/serializer"
require_relative "anthropic/assembler"
