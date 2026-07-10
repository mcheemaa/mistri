# frozen_string_literal: true

module Mistri
  module Providers
    # The OpenAI Responses API, streamed and stateless: store is always false,
    # the full history replays every turn, and encrypted reasoning items round
    # trip through the signature slots so nothing depends on server-side
    # state. Reasoning summaries stream as thinking. max_output_tokens is
    # deliberately omitted: the API defaults to the model's own ceiling.
    #
    # Provider failures fold into the stream as an error turn rather than
    # raising, matching the Anthropic provider's contract.
    class OpenAI
      DEFAULT_ORIGIN = "https://api.openai.com"
      DEFAULT_REASONING = { summary: "auto" }.freeze

      def initialize(api_key:, model: "gpt-5.5", origin: DEFAULT_ORIGIN,
                     reasoning: DEFAULT_REASONING, service_tier: nil,
                     catalog_pricing: nil, **transport_options)
        @api_key = api_key
        @model = model
        @reasoning = reasoning
        @service_tier = service_tier
        @catalog_pricing = catalog_pricing.nil? ? official_origin?(origin) : catalog_pricing
        @transport = Transport.new(origin: origin, **transport_options)
      end

      attr_reader :model

      def prices_usage?
        @catalog_pricing && Models.priced?(model) && @service_tier.to_s == "default"
      end

      def stream(messages:, system: nil, tools: [], signal: nil, **overrides, &emit)
        model = overrides.fetch(:model, @model)
        assembler = OpenAI::Assembler.new(model: model, catalog_pricing: @catalog_pricing)
        body = build_body(model, messages, system, tools, overrides)
        outcome = @transport.stream_post("/v1/responses", body: body, headers: headers,
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

      def official_origin?(origin) = origin.to_s.delete_suffix("/") == DEFAULT_ORIGIN

      def build_body(model, messages, system, tools, overrides)
        body = {
          model: model,
          input: Serializer.input_items(messages),
          stream: true,
          store: false,
          include: ["reasoning.encrypted_content"]
        }
        body[:instructions] = system if system && !system.empty?
        body[:tools] = Serializer.tools(tools) if tools.any?
        service_tier = overrides.fetch(:service_tier, @service_tier)
        body[:service_tier] = service_tier if service_tier
        reasoning = overrides.fetch(:reasoning, @reasoning)
        body[:reasoning] = reasoning if reasoning
        if (schema = overrides[:output_schema])
          body[:text] = { format: { type: "json_schema", name: "output", strict: true,
                                    schema: Schema.strict(schema, all_required: true) } }
        end
        body
      end

      def headers
        { "Authorization" => "Bearer #{@api_key}" }
      end
    end
  end
end

require_relative "openai/serializer"
require_relative "openai/assembler"
