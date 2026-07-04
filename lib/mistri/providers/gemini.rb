# frozen_string_literal: true

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
      DEFAULT_THINKING = { includeThoughts: true }.freeze

      def initialize(api_key:, model: "gemini-2.5-flash",
                     origin: "https://generativelanguage.googleapis.com",
                     thinking: DEFAULT_THINKING, **transport_options)
        @api_key = api_key
        @model = model
        @thinking = thinking
        @transport = Transport.new(origin: origin, **transport_options)
      end

      attr_reader :model

      def stream(messages:, system: nil, tools: [], signal: nil, **overrides, &emit)
        model = overrides.fetch(:model, @model)
        assembler = Gemini::Assembler.new(model: model)
        body = build_body(messages, system, tools, overrides)
        path = "/v1beta/models/#{model}:streamGenerateContent?alt=sse"
        outcome = @transport.stream_post(path, body: body, headers: headers,
                                               signal: signal) do |record|
          assembler.feed(record,
                         &emit)
        end
        outcome == :aborted ? assembler.abort(&emit) : assembler.finish(&emit)
      rescue Error => e
        assembler.fail_stream(e, &emit)
      end

      def close = @transport.close

      private

      def build_body(messages, system, tools, overrides)
        body = { contents: Serializer.contents(messages) }
        instruction = Serializer.system_instruction(system)
        body[:systemInstruction] = instruction if instruction
        body[:tools] = Serializer.tools(tools) if tools.any?
        thinking = overrides.fetch(:thinking, @thinking)
        body[:generationConfig] = { thinkingConfig: thinking } if thinking
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
