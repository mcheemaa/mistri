# frozen_string_literal: true

module Mistri
  # Agent options a child may inherit without replacing lifecycle-owned
  # provider, session, prompt, tools, task, signal, or event state.
  module ChildAgentOptions
    ALLOWED = %i[
      budget max_concurrency transform_context compaction retries skills
      before_tool after_tool context
    ].freeze
    private_constant :ALLOWED

    module_function

    def validate!(options)
      unsupported = options.keys - ALLOWED
      return if unsupported.empty?

      raise ConfigurationError,
            "unsupported sub-agent options: #{unsupported.sort.join(", ")}"
    end
  end
  private_constant :ChildAgentOptions

  class SubAgent
    DISPATCH_SPEC_VERSION = 1
    DISPATCH_SPEC_KEYS = %w[
      spec_version name session_id parent_session_id type instructions task tool_names model
    ].freeze
    UNSET_RUNTIME_FIELD = Object.new.freeze
    private_constant :DISPATCH_SPEC_KEYS, :UNSET_RUNTIME_FIELD

    # The live dependencies a host constructs for one dispatched child.
    # Mistri verifies the provider and tools against the durable spec; the
    # host owns tenant scope, backend isolation, and the freshness of every
    # object placed here.
    class Runtime
      attr_reader :provider, :system, :tools, :schema, :agent_options

      def initialize(provider:, system: nil, tools: [], schema: nil, cleanup: nil,
                     **agent_options)
        raise ArgumentError, "runtime tools must be an Array" unless tools.is_a?(Array)
        unless cleanup.nil? || cleanup.respond_to?(:call)
          raise ArgumentError, "runtime cleanup must be callable"
        end

        @provider = provider
        @system = system
        @tools = Array.new(tools).freeze
        @schema = schema
        @cleanup = cleanup
        @agent_options = agent_options.dup.freeze
        freeze
      end

      def close = @cleanup&.call
    end

    # The fail-closed boundary between a durable dispatch spec and live Ruby
    # dependencies. Kept separate from SubAgent's execution lifecycle so each
    # concern stays auditable.
    class RuntimeContract
      Resolved = Data.define(:provider, :system, :tools, :schema, :agent_options)
      private_constant :Resolved

      class << self
        def own_spec(spec)
          owned, error = ToolArguments.canonicalize(spec)
          unless error.nil? && owned.is_a?(Hash)
            raise ConfigurationError, "dispatched child spec must be a bounded JSON object"
          end

          owned
        end

        def validate_identity!(spec)
          %w[name session_id].each do |field|
            value = spec[field]
            unless value.is_a?(String) && !value.empty?
              raise ConfigurationError, "dispatched child spec needs a non-empty #{field}"
            end
          end
        end

        def bind_spec(entries, supplied)
          dispatched = entries.find { |entry| entry["type"] == Child::DISPATCHED }
          raise DispatchGrantError, "child session has no durable dispatch grant" unless dispatched

          stored = dispatched["spec"]
          return supplied if stored.nil? && supplied["spec_version"].nil?
          unless stored
            raise DispatchGrantError, "versioned child is missing its durable dispatch grant"
          end

          authoritative = own_spec(stored)
          unless supplied == authoritative
            raise DispatchGrantError, "queue payload does not match the durable dispatch grant"
          end

          authoritative
        end

        def validate_resolution!(factory:, direct:)
          supplied = direct.values.any? { |value| !value.equal?(UNSET_RUNTIME_FIELD) }
          if factory
            raise ArgumentError, "choose runtime_factory or direct runtime fields" if supplied
            unless factory.respond_to?(:call)
              raise ConfigurationError, "runtime_factory must be callable"
            end
          elsif direct.fetch(:provider).equal?(UNSET_RUNTIME_FIELD)
            raise ConfigurationError, "run_dispatched needs runtime_factory or provider"
          end
        end

        def validate_spec!(spec)
          version = spec["spec_version"]
          validate_version!(version)
          validate_v1_shape!(spec) if version == DISPATCH_SPEC_VERSION
          validate_task!(spec["task"])
          validate_model!(spec["model"], version: version)
          validate_tool_names!(spec["tool_names"])
        end

        def resolve(spec, factory:, direct:, &factory_failed)
          return resolve_factory(spec, factory, &factory_failed) if factory

          resolve_direct(direct)
        end

        def validate_runtime!(runtime, spec)
          provider = runtime.provider
          system = runtime.system
          tools = runtime.tools
          schema = runtime.schema
          options = runtime.agent_options
          validate_provider!(provider, spec["model"])
          validate_agent_options!(options)
          ordered = validate_tools!(tools, spec.fetch("tool_names"))
          Resolved.new(provider: provider, system: system, tools: ordered,
                       schema: schema, agent_options: options)
        end

        def cleanup(runtime)
          runtime&.close
          nil
        rescue StandardError => e
          e
        end

        private

        def validate_version!(version)
          return if version.nil? || version == DISPATCH_SPEC_VERSION

          raise ConfigurationError,
                "unsupported dispatched child spec version #{version.inspect}"
        end

        def validate_task!(task)
          return if task.is_a?(String) && !task.empty?

          raise ConfigurationError, "dispatched child spec needs a non-empty task"
        end

        def validate_v1_shape!(spec)
          extra = spec.keys - DISPATCH_SPEC_KEYS
          unless extra.empty?
            raise ConfigurationError,
                  "dispatched child spec has unknown fields: #{extra.join(", ")}"
          end
          validate_optional_string!(spec["parent_session_id"], "parent_session_id")
          validate_required_string!(spec["type"], "type")
          validate_optional_string!(spec["instructions"], "instructions")
        end

        def validate_model!(model, version:)
          return if version.nil? && model.nil?
          return if model.is_a?(String) && !model.empty?

          raise ConfigurationError, "dispatched child spec model must be a non-empty string"
        end

        def validate_required_string!(value, field)
          return if value.is_a?(String) && !value.empty?

          raise ConfigurationError,
                "dispatched child spec #{field} must be a non-empty string"
        end

        def validate_optional_string!(value, field)
          return if value.nil? || value.is_a?(String)

          raise ConfigurationError,
                "dispatched child spec #{field} must be a string or null"
        end

        def validate_tool_names!(names)
          valid = names.is_a?(Array) &&
                  names.all? { |name| name.is_a?(String) && !name.empty? }
          unless valid
            raise ConfigurationError,
                  "dispatched child spec tool_names must be non-empty strings"
          end
          return if names.uniq.length == names.length

          raise ConfigurationError, "dispatched child spec has duplicate tool names"
        end

        def resolve_factory(spec, factory)
          runtime = begin
            factory.call(spec)
          rescue DispatchGrantError
            yield if block_given?
            raise ConfigurationError,
                  "runtime_factory must not raise Mistri::DispatchGrantError; " \
                  "that class is reserved for queue grant verification"
          rescue StandardError
            yield if block_given?
            raise
          end
          return runtime if runtime.instance_of?(Runtime)

          raise ConfigurationError,
                "runtime_factory must return Mistri::SubAgent::Runtime"
        end

        def resolve_direct(direct)
          provider = direct.fetch(:provider)
          Runtime.new(provider: provider,
                      system: value_or_nil(direct.fetch(:system)),
                      tools: value_or(direct.fetch(:tools), []),
                      schema: value_or_nil(direct.fetch(:schema)),
                      **value_or(direct.fetch(:agent_options), {}))
        end

        def value_or(value, fallback)
          value.equal?(UNSET_RUNTIME_FIELD) ? fallback : value
        end

        def value_or_nil(value) = value_or(value, nil)

        def validate_provider!(provider, expected_model)
          unless provider.respond_to?(:stream)
            raise ConfigurationError, "background runtime provider must respond to stream"
          end
          return unless expected_model

          actual = provider.model.to_s if provider.respond_to?(:model)
          return if actual == expected_model

          raise ConfigurationError,
                "background runtime model #{actual.inspect} does not match " \
                "the granted model #{expected_model.inspect}"
        end

        def validate_agent_options!(options)
          ChildAgentOptions.validate!(options)
          return unless options.key?(:skills)

          raise ConfigurationError,
                "background runtime skills would add tools outside the durable grant"
        end

        def validate_tools!(tools, expected)
          unless tools.all?(Tool)
            raise ConfigurationError, "background runtime tools must be Mistri::Tool instances"
          end

          names = tools.map(&:name)
          if names.uniq.length != names.length
            raise ConfigurationError, "background runtime has duplicate tool names"
          end

          check_exact_grant!(expected, names)
          by_name = tools.to_h { |tool| [tool.name, tool] }
          ordered = expected.map { |name| by_name.fetch(name) }
          SubAgent.forbid_gated!(ordered)
          ordered
        end

        def check_exact_grant!(expected, names)
          missing = expected - names
          extra = names - expected
          return if missing.empty? && extra.empty?

          details = []
          details << "missing: #{missing.join(", ")}" if missing.any?
          details << "extra: #{extra.join(", ")}" if extra.any?
          raise ConfigurationError,
                "background runtime tools do not match the durable grant " \
                "(#{details.join("; ")})"
        end
      end
    end
    private_constant :RuntimeContract
  end
end
