# frozen_string_literal: true

module Mistri
  # What a tool handler may know about the run it executes inside: the
  # caller's session, the abort signal, the event stream, and the host's
  # own context object. Handlers take it as an optional second argument — a
  # proc ignores it invisibly, a lambda opts in by accepting two
  # parameters. Sub-agents are built on it; any tool that spawns work,
  # links records to the session, or streams progress can use it the same
  # way.
  #
  # app carries whatever the host passes as Agent.new(context:) — the
  # acting user, a tenant, a request — untouched. The gem provides the
  # slot, never the vocabulary:
  #
  #   agent = Mistri.agent("claude-opus-4-8", tools: tools,
  #                        context: { traveler: current_traveler })
  #   Mistri::Tool.define("book_hotel", "Books the chosen hotel.") do |args, context|
  #     Bookings.create(args, traveler: context.app[:traveler])
  #   end
  ToolContext = Data.define(:session, :signal, :emit, :app) do
    def initialize(session: nil, signal: nil, emit: nil, app: nil)
      super
    end
  end
end
