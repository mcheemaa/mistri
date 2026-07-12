# frozen_string_literal: true

require "securerandom"
require_relative "../support/integration"

# Long-run survival: compaction preserves generated state across tool turns,
# skills load on demand, and memory persists what it is told.
class TestContextManagementIntegration < Minitest::Test
  Integration.scenario(self, :one_run_survives_two_compactions) do |model|
    secret = Integration.marker
    token = "continue-#{SecureRandom.hex(12)}"
    padding = ("checkpoint context " * 80).strip
    opened = 0
    closed_with = []
    open_checkpoint = Mistri::Tool.define(
      "open_checkpoint",
      "Call first and exactly once. Returns a secret and continuation token."
    ) do
      opened += 1
      "CHECKPOINT_SECRET=#{secret}\nCONTINUATION_TOKEN=#{token}\n#{padding}"
    end
    close_checkpoint = Mistri::Tool.define(
      "close_checkpoint",
      "Call after open_checkpoint with its exact continuation token.",
      schema: -> { string :token, "Exact continuation token", required: true }
    ) do |args|
      closed_with << args["token"]
      state = args["token"] == token ? "CHECKPOINT_CLOSED=true" : "CHECKPOINT_CLOSED=false"
      "#{state}\n#{padding}"
    end
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    settings = Mistri::Compaction.new(window: 600, reserve: 550, keep_recent: 20)
    protocol = <<~PROMPT
      Complete this protocol in order:
      1. Call open_checkpoint exactly once and by itself.
      2. Call close_checkpoint exactly once and by itself, passing the exact
         CONTINUATION_TOKEN returned by open_checkpoint.
      3. After close_checkpoint succeeds, answer with only the exact
         CHECKPOINT_SECRET returned by open_checkpoint.
      Never call both tools in one turn. Never call open_checkpoint again.
    PROMPT
    agent = Mistri::Agent.new(provider: Mistri.provider(model), session:,
                              tools: [open_checkpoint, close_checkpoint], max_concurrency: 1,
                              budget: Mistri::Budget.new(turns: 4), compaction: settings,
                              system: protocol)
    events = []

    result = agent.run("Begin the checkpoint protocol now.") { |event| events << event }

    compactions = session.entries.select { |entry| entry["type"] == "compaction" }

    assert_predicate result, :completed?
    assert_equal 1, opened, "open_checkpoint did not execute exactly once"
    assert_equal [token], closed_with, "close_checkpoint did not receive the exact token"
    assert_equal 2, compactions.length, "the run did not cross two compaction boundaries"
    assert_equal(2, events.count { |event| event.type == :compaction })
    refute_includes compactions.first["summary"], secret
    assert_includes compactions.last["summary"], secret
    assert Integration.carried?(result.text, secret),
           "the final answer lost the secret: #{result.text.inspect}"

    durable = session.entries.find do |entry|
      entry["type"] == "message" && entry.dig("message", "tool_name") == "open_checkpoint"
    end

    durable_message = Mistri::Message.from_h(durable["message"])

    assert_includes durable_message.text, secret

    replay_before_answer = session.messages[0...-1]
    summary = replay_before_answer.first

    assert summary.text.start_with?(Mistri::Compaction::SUMMARY_PREFACE)
    assert_includes summary.text, secret
    refute_includes replay_before_answer.drop(1), durable_message,
                    "the original secret-bearing tool result should be outside compacted replay"
    refute(replay_before_answer.any? do |message|
      message.tool? && message.tool_name == "open_checkpoint"
    end, "the compacted replay still contains the original checkpoint result")
  end

  Integration.scenario(self, :skills_load_on_demand_and_bind) do |model|
    suffix = Integration.marker
    skills = [Mistri::Skill.new(
      name: "brand-voice",
      description: "Rules for writing any customer-facing copy or taglines.",
      body: "House voice: short sentences. Every tagline MUST end with " \
            "the exact suffix ' | #{suffix}'."
    )]
    reads = []
    agent = Mistri::Agent.new(provider: Mistri.provider(model), skills:,
                              system: "You write landing page copy.")

    result = agent.run("Write a one-line tagline for a developer conference.") do |e|
      reads << e.tool_call.name if e.type == :tool_result
    end

    assert_predicate result, :completed?
    assert_includes reads, "read_skill", "the model never pulled the skill body"
    assert Integration.carried?(result.text, suffix), "the skill's rule never applied"
  end

  Integration.scenario(self, :memory_persists_what_it_is_told) do |model|
    mascot = Integration.marker
    saved = +""
    memory = Mistri::Memory.new(read: -> { saved }, write: ->(text) { saved.replace(text) })
    agent = Mistri::Agent.new(provider: Mistri.provider(model),
                              tools: Mistri::Tools.memory(memory),
                              system: "Keep your memory document up to date when asked.")

    result = agent.run("Record in memory that the project mascot is named #{mascot}.")

    assert_predicate result, :completed?
    assert Integration.carried?(saved, mascot), "memory never got the fact: #{saved.inspect}"
  end
end
