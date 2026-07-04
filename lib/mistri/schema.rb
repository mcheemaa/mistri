# frozen_string_literal: true

module Mistri
  # A small builder for tool argument schemas, so a tool declares its inputs
  # in Ruby instead of hand-writing JSON Schema. It emits the object schema
  # every provider accepts:
  #
  #   Schema.build do
  #     string :city, "City name", required: true
  #     string :units, "Temperature units", enum: %w[celsius fahrenheit]
  #     integer :days, "Forecast length"
  #   end
  #
  # A raw JSON Schema hash is always accepted directly for anything the
  # builder does not cover, so the DSL is a convenience, never a ceiling.
  class Schema
    # instance_exec, not instance_eval: it binds self to the builder without
    # passing an argument, so a zero-arity lambda works as naturally as a proc.
    def self.build(&)
      builder = new
      builder.instance_exec(&)
      builder.to_h
    end

    def initialize
      @properties = {}
      @required = []
    end

    %i[string integer number boolean].each do |type|
      define_method(type) do |name, description = nil, required: false, enum: nil, **extra|
        prop = { type: type.to_s }
        prop[:description] = description if description
        prop[:enum] = enum if enum
        @properties[name.to_s] = prop.merge(extra)
        @required << name.to_s if required
        nil
      end
    end

    def array(name, description = nil, items: { type: "string" }, required: false, **extra)
      prop = { type: "array", items: items }
      prop[:description] = description if description
      @properties[name.to_s] = prop.merge(extra)
      @required << name.to_s if required
      nil
    end

    def object(name, description = nil, required: false, &)
      prop = self.class.build(&)
      prop[:description] = description if description
      @properties[name.to_s] = prop
      @required << name.to_s if required
      nil
    end

    def to_h
      schema = { type: "object", properties: @properties }
      schema[:required] = @required unless @required.empty?
      schema
    end
  end
end
