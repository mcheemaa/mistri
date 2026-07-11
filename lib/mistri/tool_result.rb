# frozen_string_literal: true

module Mistri
  # A tool result with model content, host-only UI, and an explicit failure
  # fact. Both channels and the error bit persist with the tool message; only
  # content and provider-supported error signaling reach the model.
  #
  #   Tool.define("edit_page", "Edits the page.") do |args|
  #     page = apply(args)
  #     Mistri::ToolResult.new(content: "Updated.", ui: { "html" => page })
  #   end
  #
  # ui must be JSON-serializable; it is stored and delivered in canonical
  # JSON form (string keys), the same shape a reloaded session reads.
  ToolResult = Data.define(:content, :ui, :error) do
    def initialize(content:, ui: nil, error: false)
      unless [true, false].include?(error)
        raise ArgumentError, "tool result error must be true or false"
      end

      super
    end

    def error? = error
  end
end
