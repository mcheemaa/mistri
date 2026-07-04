# frozen_string_literal: true

require "json"

module Mistri
  # A tool the agent can call: a name, a description, a JSON Schema for its
  # arguments, and a handler. The handler receives the parsed arguments hash
  # (string keys, exactly as the model sent them) and returns a String, a Hash
  # (serialized as JSON), or content blocks, so a tool can hand back images as
  # naturally as text.
  class Tool
    # A no-argument tool still needs a valid object schema; providers reject a
    # bare empty hash.
    EMPTY_SCHEMA = { type: "object", properties: {} }.freeze

    attr_reader :name, :description, :input_schema

    # Define a tool. Give the argument shape as a raw JSON Schema hash via
    # input_schema:, or build it in Ruby with a schema: block.
    #
    #   Tool.define("get_weather", "Weather for a city",
    #               schema: -> { string :city, "City name", required: true }) do |args|
    #     Weather.for(args["city"])
    #   end
    def self.define(name, description, input_schema: nil, schema: nil, **, &handler)
      input_schema ||= schema ? Schema.build(&schema) : EMPTY_SCHEMA
      new(name: name, description: description, input_schema: input_schema, **, &handler)
    end

    def initialize(name:, description:, input_schema: EMPTY_SCHEMA, eager_input_streaming: false,
                   &handler)
      raise ArgumentError, "tool #{name.inspect} needs a handler block" unless handler

      @name = name.to_s
      @description = description
      @input_schema = input_schema
      @eager_input_streaming = eager_input_streaming
      @handler = handler
    end

    def call(arguments)
      serialize_result(@handler.call(arguments || {}))
    end

    # The provider-facing definition; every serializer accepts this shape.
    def spec
      definition = { name: @name, description: @description, input_schema: @input_schema }
      definition[:eager_input_streaming] = true if @eager_input_streaming
      definition
    end

    private

    # Content blocks pass through so tools can return images; everything else
    # the model reads as text, with structured data as JSON, never as Ruby
    # inspect output.
    def serialize_result(result)
      case result
      when String then result
      when nil then ""
      when Array
        content = result.all? { |element| element.respond_to?(:type) || element.is_a?(String) }
        content ? result : JSON.generate(result)
      else result.respond_to?(:type) ? result : JSON.generate(result)
      end
    end
  end
end
