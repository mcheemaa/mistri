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
    # maxOutputTokens is omitted for the same reason: the API defaults to the
    # model's ceiling.
    class Gemini
      DEFAULT_ORIGIN = "https://generativelanguage.googleapis.com"
      DEFAULT_THINKING = { includeThoughts: true }.freeze

      def initialize(api_key:, model: "gemini-2.5-flash",
                     origin: DEFAULT_ORIGIN, thinking: DEFAULT_THINKING,
                     service_tier: nil, catalog_pricing: nil, **transport_options)
        @api_key = api_key
        @model = model
        @thinking = thinking
        @service_tier = service_tier
        @catalog_pricing = catalog_pricing.nil? ? official_origin?(origin) : catalog_pricing
        @transport = Transport.new(origin: origin, **transport_options)
      end

      attr_reader :model

      def prices_usage?
        tier_known = @service_tier.nil? || %w[unspecified standard].include?(@service_tier.to_s)
        @catalog_pricing && Models.priced?(model) && tier_known
      end

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
        outcome = @transport.stream_post(path, body: body, headers: headers,
                                               signal: signal) do |record|
          assembler.feed(record,
                         &delivery)
        end
        outcome == :aborted ? assembler.abort(&delivery) : assembler.finish(&delivery)
      rescue EventDelivery::Failure => e
        raise EventDelivery.unwrap(e, delivery)
      rescue Error => e
        assembler.fail_stream(e, &emit)
      end

      def close = @transport.close

      private

      def official_origin?(origin) = origin.to_s.delete_suffix("/") == DEFAULT_ORIGIN

      def build_body(messages, system, tools, overrides)
        body = { contents: Serializer.contents(messages) }
        instruction = Serializer.system_instruction(system)
        body[:systemInstruction] = instruction if instruction
        body[:tools] = Serializer.tools(tools) if tools.any?
        service_tier = overrides.fetch(:service_tier, @service_tier)
        body[:serviceTier] = service_tier if service_tier
        config = {}
        thinking = overrides.fetch(:thinking, @thinking)
        config[:thinkingConfig] = thinking if thinking
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
