# frozen_string_literal: true

require "json"

module Mistri
  # A tool the agent can call: a name, a description, a JSON Schema for its
  # arguments, and a handler. Model calls reach the handler as canonical
  # argument hashes, optionally normalized by the tool before policy sees
  # them. Trusted direct calls keep ordinary Ruby Hash semantics.
  class Tool
    # A no-argument tool still needs a valid object schema; providers reject a
    # bare empty hash.
    EMPTY_SCHEMA = {
      type: "object", properties: {}.freeze, required: [].freeze,
      additionalProperties: false
    }.freeze

    attr_reader :name, :description, :input_schema, :timeout

    # Define a tool. Give the argument shape as a JSON Schema value via
    # input_schema:, or build it in Ruby with a schema: block. The result is
    # canonicalized and owned once so provider and local semantics cannot drift.
    #
    #   Tool.define("get_weather", "Weather for a city",
    #               schema: -> { string :city, "City name", required: true }) do |args|
    #     Weather.for(args["city"])
    #   end
    def self.define(name, description, input_schema: nil, schema: nil, **, &handler)
      raise ArgumentError, "choose input_schema or schema, not both" if schema && !input_schema.nil?

      input_schema = schema ? Schema.build(&schema) : EMPTY_SCHEMA if input_schema.nil?
      new(name: name, description: description, input_schema: input_schema, **, &handler)
    end

    def initialize(name:, description:, input_schema: EMPTY_SCHEMA, eager_input_streaming: false,
                   needs_approval: false, ends_turn: false, timeout: nil,
                   argument_normalizer: nil, argument_validator: nil,
                   complete_argument_validator: nil, &handler)
      raise ArgumentError, "tool #{name.inspect} needs a handler block" unless handler
      unless argument_normalizer.nil? || argument_normalizer.respond_to?(:call)
        raise ArgumentError, "argument_normalizer must be callable"
      end
      unless argument_validator.nil? || argument_validator.respond_to?(:call)
        raise ArgumentError, "argument_validator must be callable"
      end
      unless complete_argument_validator.nil? || complete_argument_validator.respond_to?(:call)
        raise ArgumentError, "complete_argument_validator must be callable"
      end
      if argument_validator && complete_argument_validator
        raise ArgumentError,
              "choose argument_validator or complete_argument_validator, not both"
      end

      @name = name.to_s
      @description = description
      @schema_validator = Schema.tool_validator(
        input_schema, complete: !complete_argument_validator.nil?
      )
      @input_schema = @schema_validator.schema
      @eager_input_streaming = eager_input_streaming
      @needs_approval = needs_approval
      @ends_turn = ends_turn
      @timeout = timeout
      @argument_normalizer = argument_normalizer
      @argument_validator = argument_validator
      @complete_argument_validator = complete_argument_validator
      @handler = handler
    end

    # A handler may return a ToolResult to add host-only UI or declare a
    # model-readable failure. Its ui payload is canonicalized through JSON
    # here so the live event and a reloaded session read the identical shape.
    #
    # Handlers receive (arguments, context). A proc that declares one
    # parameter ignores the context invisibly; a lambda opts in by arity.
    # Direct calls are trusted host invocations: they apply the compatibility
    # normalizer, but do not canonicalize or validate as model calls do. The
    # executor marks arguments the Agent already prepared so subclasses keep
    # the historical #call extension point without running normalization twice.
    def call(arguments, context = ToolContext.new)
      arguments = normalize_arguments(arguments || {}) unless prepared_context?(context)
      result = invoke(arguments || {}, context)
      return serialize_result(result) unless result.is_a?(ToolResult)

      result.with(content: serialize_result(result.content),
                  ui: result.ui && JSON.parse(JSON.generate(result.ui)))
    end

    # Normalization is an explicit per-tool migration boundary, never a
    # global coercion policy. Agent calls this once before policy; direct
    # trusted invocations get the same compatibility behavior through #call.
    def normalize_arguments(arguments)
      return arguments unless @argument_normalizer

      normalized = @argument_normalizer.call(arguments)
      raise ArgumentError, "argument_normalizer must return a Hash" unless normalized.is_a?(Hash)

      normalized
    end

    # Core validation is always authoritative for its portable subset. A
    # supplemental validator adds domain rules; an explicitly complete one
    # additionally owns schema interactions core cannot represent.
    def argument_violations(arguments)
      validate_arguments(arguments, owned: false)
    end

    # Agent has already moved the value through ToolCall's ownership boundary,
    # so its hot path can avoid copying the same immutable JSON twice.
    def prepared_argument_violations(arguments)
      validate_arguments(arguments, owned: true)
    end

    # Whether this call should pause for a human. true/false, or a callable
    # given the parsed arguments so a tool can gate only the risky calls
    # (needs_approval: ->(args) { args["amount"].to_i > 100 }).
    def needs_approval?(arguments)
      @needs_approval.respond_to?(:call) ? @needs_approval.call(arguments) : @needs_approval
    end

    # A tool that is the last word of its turn: once it executes, the loop
    # ends the run instead of prompting the model again. This is how a tool
    # like ask_user hands the floor to a human structurally, with no prompt
    # discipline required; the answer arrives as the next run's input.
    def ends_turn?
      @ends_turn
    end

    # The provider-facing definition; every serializer accepts this shape.
    def spec
      definition = { name: @name, description: @description, input_schema: @input_schema }
      definition[:eager_input_streaming] = true if @eager_input_streaming
      definition
    end

    private

    def prepared_context?(context)
      context.respond_to?(:arguments_prepared?) && context.arguments_prepared?
    end

    def validate_arguments(arguments, owned:)
      unless owned
        arguments, error = ToolArguments.canonicalize(arguments)
        return ["$ validation limit exceeded"] if ToolArguments.resource_error?(error)
        return ["$ must be valid JSON"] if error
      end

      errors = @schema_validator.violations(arguments, owned: true)
      custom_validator = @complete_argument_validator || @argument_validator
      return errors if errors.any? || !custom_validator

      custom = custom_validator.call(arguments, @input_schema)
      unless custom.is_a?(Array) && custom.all?(String)
        name = @complete_argument_validator ? "complete_argument_validator" : "argument_validator"
        raise TypeError, "#{name} must return an Array of Strings"
      end

      custom
    end

    def invoke(arguments, context)
      if @handler.lambda? && @handler.arity.between?(0, 1)
        @handler.arity.zero? ? @handler.call : @handler.call(arguments)
      else
        @handler.call(arguments, context)
      end
    end

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
