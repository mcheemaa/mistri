# frozen_string_literal: true

module Mistri
  # Durable knowledge that outlives a session, living wherever the host says:
  # an org's row, a user record, a file. What memory means (per org, per
  # user, per project) is the host's call; Mistri only reads and replaces it.
  #
  #   memory = Mistri::Memory.new(
  #     read: -> { org.agent_memory.to_s },
  #     write: ->(text) { org.update!(agent_memory: text) }
  #   )
  #   agent = Mistri.agent("claude-opus-4-8", tools: [*Mistri::Tools.memory(memory)])
  class Memory
    def initialize(read:, write:)
      @read = read
      @write = write
    end

    def read = @read.call.to_s

    def replace(content)
      @write.call(content.to_s)
      nil
    end
  end
end
