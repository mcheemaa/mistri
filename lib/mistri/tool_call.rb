# frozen_string_literal: true

require_relative "tool_arguments"

module Mistri
  # One immutable tool invocation requested by the model. Completed arguments
  # are deeply owned JSON; arguments_error records why an unsafe value became
  # nil instead of letting it cross the execution boundary. Signature carries
  # opaque replay state; provider_call_id distinguishes an optional wire ID
  # from Mistri's always-present session correlation ID.
  ToolCall = Data.define(:id, :name, :arguments, :signature, :arguments_error,
                         :provider_call_id) do
    def initialize(id:, name:, arguments: {}, signature: nil, arguments_error: nil,
                   provider_call_id: nil, canonicalize: true)
      id = id.dup.freeze if id.is_a?(String)
      name = name.dup.freeze if name.is_a?(String)
      signature = signature.dup.freeze if signature.is_a?(String)
      provider_call_id = provider_call_id.dup.freeze if provider_call_id.is_a?(String)
      @arguments_owned = canonicalize || !arguments_error.nil?
      if arguments_error.nil?
        arguments, arguments_error = ToolArguments.canonicalize(arguments) if canonicalize
      else
        arguments = nil
        arguments_error = ToolArguments.normalize_error(arguments_error)
      end
      super(id:, name:, arguments:, signature:, arguments_error:, provider_call_id:)
    end

    def type = :tool_call

    def arguments_error? = !arguments_error.nil?

    def arguments_owned? = @arguments_owned

    # Data#with bypasses custom initializers; this value must re-enter the
    # ownership boundary whenever a normalizer replaces its arguments.
    def with(id: self.id, name: self.name, arguments: self.arguments,
             signature: self.signature, arguments_error: self.arguments_error,
             provider_call_id: self.provider_call_id)
      self.class.new(id:, name:, arguments:, signature:, arguments_error:, provider_call_id:)
    end

    def to_h
      hash = { type: :tool_call, id:, name: }.compact
      hash[:arguments] = arguments
      hash[:signature] = signature unless signature.nil?
      hash[:arguments_error] = arguments_error unless arguments_error.nil?
      hash[:provider_call_id] = provider_call_id unless provider_call_id.nil?
      hash
    end
  end
end
