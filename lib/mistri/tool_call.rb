# frozen_string_literal: true

module Mistri
  # One tool invocation requested by the model. `arguments` is the parsed Hash
  # exactly as the model emitted it, string keys and all; the top level is owned
  # and frozen, nested values stay as parsed. `signature` is the opaque
  # reasoning payload some providers attach to the call and require echoed back,
  # such as Gemini's thoughtSignature.
  ToolCall = Data.define(:id, :name, :arguments, :signature) do
    def initialize(id:, name:, arguments: {}, signature: nil)
      super(id:, name:, arguments: arguments.dup.freeze, signature:)
    end

    def type = :tool_call

    def to_h = { type: :tool_call, id:, name:, arguments:, signature: }.compact
  end
end
