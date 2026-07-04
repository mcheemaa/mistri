# frozen_string_literal: true

module Mistri
  module Tools
    module_function

    def read_memory(memory)
      Tool.define("read_memory",
                  "Read the durable memory: knowledge kept across sessions. Check it " \
                  "before starting work that earlier sessions may have learned about.") do |_args|
        content = memory.read
        content.empty? ? "Memory is empty." : content
      end
    end
  end
end
