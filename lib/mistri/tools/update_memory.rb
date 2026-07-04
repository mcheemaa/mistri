# frozen_string_literal: true

module Mistri
  module Tools
    module_function

    # Whole-document replace on purpose: the model rewrites memory as one
    # coherent text instead of appending fragments that drift.
    def update_memory(memory)
      Tool.define("update_memory",
                  "Replace the durable memory with an updated version. Pass the FULL " \
                  "text: what you were given plus what you learned, rewritten to stay " \
                  "short and current.",
                  schema: lambda {
                    string :content, "The complete new memory text", required: true
                  }) do |args|
        memory.replace(args["content"])
        "Memory updated (#{args["content"].to_s.length} chars)."
      end
    end
  end
end
