# frozen_string_literal: true

require_relative "schema_capabilities"

module Mistri
  module Providers
    # The Gemini API (v1beta generateContent), streamed over SSE and
    # stateless: the full history replays every turn.
    #
    # Thinking is deliberately unconstrained: no budget, no level, only
    # includeThoughts so summaries stream for the UI. The model's own defaults
    # decide how much to think, and a host override passes through verbatim.
    # maxOutputTokens is sent only when the provider or a stream call is given
    # max_tokens. Otherwise the API's default applies, which on Gemini 4 is
    # the 65,536 tokens of one request.
    #
    # A Gemini 4 model returns at most that many tokens for one request. An
    # answer that needs more ends its request with CONTINUATION and a token,
    # and the same request sent again with the token goes on from there.
    class Gemini
      DEFAULT_ORIGIN = "https://generativelanguage.googleapis.com"
      DEFAULT_THINKING = { includeThoughts: true }.freeze

      def initialize(api_key:, model: "gemini-3.8-flash",
                     origin: DEFAULT_ORIGIN, thinking: DEFAULT_THINKING, max_tokens: nil,
                     service_tier: nil, catalog_pricing: nil, **transport_options)
        @api_key = api_key
        @model = model
        @thinking = thinking
        @max_tokens = max_tokens
        @service_tier = service_tier
        @official = official_origin?(origin)
        @catalog_pricing = catalog_pricing.nil? ? @official : catalog_pricing
        @transport = Transport.new(origin: origin, **transport_options)
      end

      attr_reader :model

      def prices_usage?
        tier_known = @service_tier.nil? || %w[unspecified standard].include?(@service_tier.to_s)
        @catalog_pricing && Models.priced?(model) && tier_known
      end

      # The API has no system message in the middle of a conversation, so a
      # reminder is sent as text of a user turn.
      def system_messages? = false

      def native_output_schema(schema)
        return unless Models.find(model)&.provider == :gemini

        SchemaCapabilities.derive(schema, :gemini)
      end

      def stream(messages:, system: nil, tools: [], signal: nil, **overrides, &emit)
        delivery = EventDelivery.wrap(emit)
        model = overrides.fetch(:model, @model)
        service_tier = overrides.fetch(:service_tier, @service_tier)
        assembler = Gemini::Assembler.new(model: model, catalog_pricing: @catalog_pricing,
                                          service_tier:)
        assembler.start(&delivery)
        body = build_body(messages, system, tools, overrides)
        path = "/v1beta/models/#{model}:streamGenerateContent?alt=sse"
        outcome = nil
        loop do
          # A tool call's arguments arrive as an object inside the record, so
          # the record's tokens are counted before it is parsed.
          outcome = @transport.stream_post(path, body:, headers:, signal:,
                                                 count_tokens: true) do |record|
            assembler.feed(record, &delivery)
          end
          token = assembler.continue unless outcome == :aborted
          break unless token

          body = body.merge(continuationToken: token)
        end
        outcome == :aborted ? assembler.abort(&delivery) : assembler.finish(&delivery)
      rescue EventDelivery::Failure => e
        raise EventDelivery.unwrap(e, delivery)
      rescue Error => e
        assembler.fail_stream(e, &emit)
      end

      # The API's own count of the input tokens of the request that stream
      # would send for the same arguments. It counts a thought signature
      # lower than a request does, by about 8 tokens for each tool call. Nil
      # on another origin, which may not have the endpoint.
      def count_tokens(messages:, system: nil, tools: [], **overrides)
        return nil unless @official

        model = overrides.fetch(:model, @model)
        request = build_body(messages, system, tools, overrides)
                  .slice(:contents, :systemInstruction, :tools).merge(model: "models/#{model}")
        @transport.post("/v1beta/models/#{model}:countTokens",
                        body: { generateContentRequest: request }, headers:).fetch("totalTokens")
      end

      def close = @transport.close

      private

      def official_origin?(origin) = origin.to_s.delete_suffix("/") == DEFAULT_ORIGIN

      def build_body(messages, system, tools, overrides)
        body = { contents: Serializer.contents(messages) }
        instruction = Serializer.system_instruction(system, messages)
        body[:systemInstruction] = instruction if instruction
        body[:tools] = Serializer.tools(tools) if tools.any?
        service_tier = overrides.fetch(:service_tier, @service_tier)
        body[:serviceTier] = service_tier if service_tier
        config = {}
        thinking = overrides.fetch(:thinking, @thinking)
        config[:thinkingConfig] = thinking if thinking
        max_tokens = overrides.fetch(:max_tokens, @max_tokens)
        config[:maxOutputTokens] = max_tokens if max_tokens
        # Constrained decoding combines with tools only on 3-series models
        # (preview); with tools present the task loop's validate-and-fix
        # pass carries the guarantee instead.
        if (schema = overrides[:output_schema]) && tools.empty?
          config[:responseMimeType] = "application/json"
          config[:responseJsonSchema] = Schema.strict(schema)
        end
        body[:generationConfig] = config unless config.empty?
        body
      end

      def headers
        { "x-goog-api-key" => @api_key }
      end
    end
  end
end

require_relative "gemini/serializer"
require_relative "gemini/assembler"
