# frozen_string_literal: true

require_relative "test_helper"

# Steering: a user message queued from any process folds into a running
# exchange at the next turn boundary, and one that lands as the model
# finishes cleanly extends the run so it gets answered.
class TestAgentSteering < Minitest::Test
  def test_a_steer_folds_in_before_the_next_turn
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "paint", arguments: {} }] },
                                             { text: "A blue page." }
                                           ])
    # The tool steers through a separate session handle on the same store,
    # the way another process would mid-run.
    tool = Mistri::Tool.define("paint", "Paints.") do
      Mistri::Session.new(store:, id: session.id).steer("make it blue")
      "painted"
    end

    result = Mistri::Agent.new(provider:, tools: [tool], session:).run("paint the page")

    assert_predicate result, :completed?
    steered = provider.requests.last[:messages]

    assert(steered.any? { |m| m.user? && m.text == "make it blue" })
    roles = session.messages.map { |m| m.tool? ? :tool : m.role }

    assert_equal %i[user assistant tool user assistant], roles,
                 "the steer folds in after the tool results it arrived during"
  end

  def test_a_steer_during_the_final_answer_extends_the_run
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    provider = Mistri::Providers::Fake.new(turns: [{ text: "Done." }, { text: "Now in blue." }])
    agent = Mistri::Agent.new(provider:, session:)
    steered = false

    result = agent.run("build it") do |event|
      next unless event.type == :text_end && !steered

      steered = true
      Mistri::Session.new(store:, id: session.id).steer("make it blue")
    end

    assert_predicate result, :completed?
    assert_equal "Now in blue.", result.text
    assert(provider.requests.last[:messages].any? { |m| m.user? && m.text == "make it blue" })
  end

  def test_a_steer_while_idle_leads_the_next_run
    provider = Mistri::Providers::Fake.new(turns: [{ text: "ok" }])
    agent = Mistri::Agent.new(provider:)
    agent.session.steer("context first")

    agent.run("the question")

    texts = provider.requests.last[:messages].select(&:user?).map(&:text)

    assert_equal ["context first", "the question"], texts
  end

  def test_an_aborted_run_does_not_extend_on_a_pending_steer
    provider = Mistri::Providers::Fake.new(turns: [{ text: "partial", stop_reason: :aborted }])
    agent = Mistri::Agent.new(provider:)
    steered = false

    result = agent.run("go") do |event|
      next unless event.type == :text_end && !steered

      steered = true
      agent.session.steer("keep going")
    end

    assert_predicate result, :aborted?
    assert_equal 1, agent.session.pending_steers.length,
                 "the steer stays pending for the next run"
  end

  def test_a_steer_composes_with_approval_resume
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    gated = Mistri::Tool.define("send_gift", "Sends.", needs_approval: true) { "sent" }
    gift_call = { tool_calls: [{ name: "send_gift", arguments: {} }] }
    first = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns: [gift_call]),
                              tools: [gated], session:)
    call = first.run("send it").pending.first

    # While suspended, the user adds a thought and then approves.
    session.steer("gift wrap it too")
    session.approve(call.id)

    provider = Mistri::Providers::Fake.new(turns: [{ text: "Sent, wrapped." }])
    result = Mistri::Agent.new(provider:, tools: [gated],
                               session: Mistri::Session.new(store:, id: session.id)).resume

    assert_predicate result, :completed?
    resumed = provider.requests.last[:messages]

    assert(resumed.any? { |m| m.user? && m.text == "gift wrap it too" })
    assert(resumed.any?(&:tool?), "the approved tool result precedes the steer")
  end

  def test_pending_steers_are_readable_for_display
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    session.steer("one")
    session.steer("two")

    texts = session.pending_steers.map { |s| s.dig("message", "content", 0, "text") }

    assert_equal %w[one two], texts
  end
end
