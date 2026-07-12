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
      assert_equal recipient, sent.first, "the tool never got the exact recipient"
      assert Integration.saw?(resumed.text, recipient), "the answer lost the recipient"
    end
  end

  Integration.scenario(self, :steering_lands_mid_run) do |model|
    keyword = Integration.marker
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
    assert Integration.carried?(result.text, keyword), "the steer never reached the model"
  end

  # A crash between the assistant turn and its tool results leaves calls
  # unanswered, which providers reject on every later turn. Healing must
  # make the resumed context acceptable to the real API.
  Integration.scenario(self, :a_crashed_run_resumes_healed) do |model|
    venue = Integration.marker
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    calls = [Mistri::ToolCall.new(id: "call_1", name: "book_venue",
                                  arguments: { "city" => "Lisbon" })]
    session.append_message(Mistri::Message.user("Book us a venue, then confirm."))
    session.append_message(Mistri::Message.assistant(tool_calls: calls))

    booked = Mistri::Tool.define("book_venue", "Books the venue.",
                                 schema: -> { string :city, "City" }) { "Booked #{venue}." }
    agent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [booked], session:)

    result = agent.run("Run book_venue for Lisbon again now, then repeat " \
                       "the venue name it returns back to me.")

    assert_predicate result, :completed?
    assert Integration.carried?(result.text, venue),
           "the healed session never recovered: #{result.text}"
  end
end
