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
      DEFAULT_REASONING = { summary: "auto" }.freeze

      def initialize(api_key:, model: "gpt-5.5", origin: "https://api.openai.com",
                     reasoning: DEFAULT_REASONING, **transport_options)
        @api_key = api_key
        @model = model
        @reasoning = reasoning
        @transport = Transport.new(origin: origin, **transport_options)
      end

      attr_reader :model

      def stream(messages:, system: nil, tools: [], signal: nil, **overrides, &emit)
        model = overrides.fetch(:model, @model)
        assembler = OpenAI::Assembler.new(model: model)
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
        reasoning = overrides.fetch(:reasoning, @reasoning)
        body[:reasoning] = reasoning if reasoning
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
