# frozen_string_literal: true

# Fire-and-forget human approval. The run suspends without executing the
# gated tool; the decision is a session write (here immediate, in production
# a controller action days later); resume settles it and finishes. Sessions
# live in JSONL files so every step could happen in a different process.
# Needs ANTHROPIC_API_KEY.
#
#   ruby examples/approval.rb

require "mistri"
require "tmpdir"

Dir.mktmpdir do |dir|
  store = Mistri::Stores::JSONL.new(dir)
  session = Mistri::Session.new(store:)

  send_email = Mistri::Tool.define(
    "send_email", "Sends a real email.", needs_approval: true,
                                         schema: -> { string :to, "Recipient", required: true }
  ) do |args|
    "email queued for #{args["to"]}"
  end

  agent = Mistri.agent("claude-opus-5-5", tools: [send_email], session:)
  result = agent.run("Send a welcome email to Ana.")
  puts "suspended: #{result.awaiting_approval?} (nothing executed)"

  # Any process can decide: a bare session is enough.
  Mistri::Session.new(store:, id: session.id).approve(result.pending.first.id)

  reloaded = Mistri::Session.new(store:, id: session.id)
  resumed = Mistri.agent("claude-opus-5-5", tools: [send_email], session: reloaded).resume
  puts "resumed: #{resumed.status}"
  puts resumed.text
end
