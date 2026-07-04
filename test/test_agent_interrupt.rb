# frozen_string_literal: true

require_relative "test_helper"

# The interaction that matters most: stop mid-run, then send a new message and
# have the run continue cleanly. The aborted turn must leave a replay-valid
# transcript so the next call needs no repair.
class TestAgentInterrupt < Minitest::Test
  def test_aborting_during_tools_pairs_every_call_and_resumes_clean
    signal = Mistri::AbortSignal.new
    # Two tools this turn; one trips the abort, so the executor must give the
    # other an interrupted result rather than leave it dangling.
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "stop_here", arguments: {} },
                                                            { name: "never_runs",
                                                              arguments: {} }] },
                                             { text: "continued after the stop" }
                                           ])
    stop_here = Mistri::Tool.define("stop_here", "Trips the abort.") do
      signal.abort!(:user_stop)
      "stopped"
    end
    never = Mistri::Tool.define("never_runs", "Should not complete.") { flunk "ran despite abort" }
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    agent = Mistri::Agent.new(provider:, tools: [stop_here, never], session:)

    agent.run("do two things", signal:)

    roles = session.messages.map(&:role)

    assert_equal %i[user assistant tool tool], roles
    tool_ids = session.messages.select(&:tool?).map(&:tool_call_id)
    call_ids = session.messages[1].tool_calls.map(&:id)

    assert_equal call_ids.sort, tool_ids.sort, "every tool_use must have a paired tool result"

    # Resume on the same session: a fresh agent continues with no repair.
    resumed = Mistri::Agent.new(provider:, tools: [stop_here, never], session:)
    message = resumed.run("keep going")

    assert_equal "continued after the stop", message.text
    assert_equal :stop, message.stop_reason
  end
end
