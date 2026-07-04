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
                   needs_approval: false, &handler)
      raise ArgumentError, "tool #{name.inspect} needs a handler block" unless handler

      @name = name.to_s
      @description = description
      @input_schema = input_schema
      @eager_input_streaming = eager_input_streaming
      @needs_approval = needs_approval
      @handler = handler
    end

    # A handler may return a ToolResult to speak on two channels; its ui
    # payload is canonicalized through JSON here so the live event and a
    # reloaded session read the identical shape.
    def call(arguments)
      result = @handler.call(arguments || {})
      return serialize_result(result) unless result.is_a?(ToolResult)

      result.with(content: serialize_result(result.content),
                  ui: result.ui && JSON.parse(JSON.generate(result.ui)))
    end

    # Whether this call should pause for a human. true/false, or a callable
    # given the parsed arguments so a tool can gate only the risky calls
    # (needs_approval: ->(args) { args["amount"].to_i > 100 }).
    def needs_approval?(arguments)
      @needs_approval.respond_to?(:call) ? @needs_approval.call(arguments) : @needs_approval
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
