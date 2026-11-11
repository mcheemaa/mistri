# frozen_string_literal: true

module Mistri
  # A tool result with model content, host-only UI, and an explicit failure
  # fact. Both channels and the error bit persist with the tool message; only
  # content and provider-supported error signaling reach the model.
  #
  #   Tool.define("edit_page", "Edits the page.", schema: -> {
  #     object :changes, "Page changes", required: true
  #   }) do |args|
  #     page = apply(args.fetch("changes"))
  #     Mistri::ToolResult.new(content: "Updated.", ui: { "html" => page })
  #   end
  #
  # ui must be JSON-serializable; it is stored and delivered in canonical
  # JSON form (string keys), the same shape a reloaded session reads.
  #
  # loads names deferred tools this result makes available: the model can
  # call them from its next step, in this run and in later ones.
  ToolResult = Data.define(:content, :ui, :error, :loads) do
    def initialize(content:, ui: nil, error: false, loads: nil)
      unless [true, false].include?(error)
        raise ArgumentError, "tool result error must be true or false"
      end
      unless loads.nil? || (loads.is_a?(Array) && loads.all?(String))
        raise ArgumentError, "tool result loads must be an array of tool names"
      end

      super
    end

    def error? = error
  end
end
