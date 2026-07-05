# frozen_string_literal: true

require_relative "../support/integration"
require "tmpdir"

# Fire-and-forget approval across real files and processes-worth of
# separation, and mid-run steering.
class TestControlSurfacesIntegration < Minitest::Test
  Integration.scenario(self, :approval_suspends_then_resumes) do |model|
    Dir.mktmpdir do |dir|
      store = Mistri::Stores::JSONL.new(dir)
      recipient = Integration.codename
      sent = []
      gift = Mistri::Tool.define("send_gift", "Sends a real gift to a person.",
                                 needs_approval: true,
                                 schema: lambda {
                                   string :to, "Recipient name", required: true
                                 }) do |args|
        sent << args["to"]
        "gift queued for #{args["to"]}"
      end
      session = Mistri::Session.new(store:)
      first = Mistri::Agent.new(provider: Mistri.provider(model), tools: [gift], session:)

      suspended = first.run("Send a gift to #{recipient}. Use the tool.")

      assert_predicate suspended, :awaiting_approval?
      assert_empty sent, "the gated tool ran before approval"

      # The decision arrives later, from a bare session on the same files.
      Mistri::Session.new(store:, id: session.id).approve(suspended.pending.first.id)

      resumed = Mistri::Agent.new(provider: Mistri.provider(model), tools: [gift],
                                  session: Mistri::Session.new(store:, id: session.id)).resume

      assert_predicate resumed, :completed?
      assert Integration.saw?(sent.first, recipient), "the tool never got the recipient"
      assert Integration.saw?(resumed.text, recipient), "the answer lost the recipient"
    end
  end

  Integration.scenario(self, :steering_lands_mid_run) do |model|
    keyword = Integration.codename
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    theme = Mistri::Tool.define("lookup_theme", "The site theme to use.") do
      # Another process steers while the tool runs.
      Mistri::Session.new(store:, id: session.id)
                     .steer("Update: the tagline MUST include the word #{keyword}.")
      "theme: minimal"
    end
    agent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [theme], session:,
                              system: "Call lookup_theme first, then write the tagline.")

    result = agent.run("Write a one-line tagline for the landing page.")

    assert_predicate result, :completed?
    assert Integration.saw?(result.text, keyword), "the steer never reached the model"
  end
end
