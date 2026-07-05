# frozen_string_literal: true

module Mistri
  # What a tool handler may know about the run it executes inside: the
  # caller's session, the abort signal, and the event stream. Handlers take
  # it as an optional second argument — a proc ignores it invisibly, a
  # lambda opts in by accepting two parameters. Sub-agents are built on it;
  # any tool that spawns work, links records to the session, or streams
  # progress can use it the same way.
  ToolContext = Data.define(:session, :signal, :emit) do
    def initialize(session: nil, signal: nil, emit: nil)
      super
    end
  end
end
