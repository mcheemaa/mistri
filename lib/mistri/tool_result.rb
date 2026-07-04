# frozen_string_literal: true

module Mistri
  # A two-channel tool result: content goes to the model, ui goes only to the
  # host. The ui payload rides the tool message and its :tool_result event,
  # persists with the session for transcript re-renders, and never reaches a
  # provider. Return one from a handler when the UI needs more than the model
  # should read or pay for: full query rows behind a compact answer, the
  # updated document behind "saved".
  #
  #   Tool.define("edit_page", "Edits the page.") do |args|
  #     page = apply(args)
  #     Mistri::ToolResult.new(content: "Updated.", ui: { "html" => page })
  #   end
  #
  # ui must be JSON-serializable; it is stored and delivered in canonical
  # JSON form (string keys), the same shape a reloaded session reads.
  ToolResult = Data.define(:content, :ui) do
    def initialize(content:, ui: nil)
      super
    end
  end
end
