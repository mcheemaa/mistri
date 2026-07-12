# frozen_string_literal: true

require_relative "schema_capabilities"

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
      DEFAULT_ORIGIN = "https://api.anthropic.com"
      VERSION_HEADER = "2023-06-01"
      DEFAULT_THINKING = { type: "adaptive", display: "summarized" }.freeze

      # Messages API parameters passed through verbatim from a stream override.
      PASSTHROUGH = %i[temperature top_p top_k stop_sequences metadata tool_choice].freeze
      # The ceiling for an uncatalogued model: high enough for headroom, low
      # enough that every current model accepts it. Catalog a model to unlock
      # its real output limit.
      UNKNOWN_MODEL_MAX_TOKENS = 64_000

      def initialize(api_key:, model: "claude-opus-4-8", origin: DEFAULT_ORIGIN,
                     max_tokens: nil, thinking: DEFAULT_THINKING, cache: true,
                     service_tier: nil, catalog_pricing: nil,
                     **transport_options)
        @api_key = api_key
        @model = model
        @max_tokens = max_tokens
        @thinking = thinking
        @cache = cache
        @service_tier = service_tier
        @catalog_pricing = catalog_pricing.nil? ? official_origin?(origin) : catalog_pricing
        @transport = Transport.new(origin: origin, **transport_options)
      end

      attr_reader :model

      def prices_usage?
        @catalog_pricing && Models.priced?(model) && @service_tier.to_s == "standard_only"
      end

      def native_output_schema(schema)
        return unless Models.find(model)&.provider == :anthropic

        SchemaCapabilities.derive(schema, :anthropic)
      end

      def stream(messages:, system: nil, tools: [], signal: nil, **overrides, &emit)
        delivery = EventDelivery.wrap(emit)
        model = overrides.fetch(:model, @model)
        assembler = Anthropic::Assembler.new(model: model, catalog_pricing: @catalog_pricing)
        assembler.start(&delivery)
        body = build_body(model, messages, system, tools, overrides)
        outcome = @transport.stream_post("/v1/messages", body: body, headers: headers,
                                                         signal: signal) do |record|
          assembler.feed(
            record, &delivery
          )
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
        service_tier = overrides.fetch(:service_tier, @service_tier)
        body[:service_tier] = service_tier if service_tier
        thinking = thinking_for(model, overrides)
        body[:thinking] = thinking if thinking
        if (schema = overrides[:output_schema])
          body[:output_config] = { format: { type: "json_schema",
                                             schema: Schema.strict(schema) } }
        end
        body.merge(PASSTHROUGH.each_with_object({}) do |key, params|
          params[key] = overrides[key] if overrides.key?(key)
        end)
      end

      # Adaptive thinking 400s on budget-only models like Haiku 4.5, so the
      # adaptive default is dropped for a model the catalog marks :budget; a
      # host that wants thinking there passes an explicit budget config. An
      # unknown model keeps the default, since new models are adaptive.
      def thinking_for(model, overrides)
        thinking = overrides.fetch(:thinking, @thinking)
        return thinking unless thinking && thinking[:type] == "adaptive"
        return nil if Models.thinking(model) == :budget

        thinking
      end

      # The API requires max_tokens and bills only actual output, so the
      # default is the model's own catalogued ceiling: full headroom, no
      # silent truncation. An uncatalogued model falls back safely.
      def max_tokens_for(model, overrides)
        overrides.fetch(:max_tokens) do
          @max_tokens || Models.max_output(model) || UNKNOWN_MODEL_MAX_TOKENS
        end
      end

      def headers
        { "x-api-key" => @api_key, "anthropic-version" => VERSION_HEADER }
      end
    end
  end
end

require_relative "anthropic/serializer"
require_relative "anthropic/assembler"
