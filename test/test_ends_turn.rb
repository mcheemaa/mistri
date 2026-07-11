# frozen_string_literal: true

require_relative "test_helper"

# ends_turn: a tool that is the last word of its turn. Once it executes,
# the loop ends the run instead of prompting the model again, which is how
# an ask_user tool hands the floor to a human structurally. Every test
# scripts the Fake with no turns to spare: if the loop asked the model one
# more question, the provider would raise.
class TestEndsTurn < Minitest::Test
  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def ask_user(asked = [])
    Mistri::Tool.define("ask_user", "Put a question to the human and stop.",
                        ends_turn: true,
                        schema: -> { string :question, "The question", required: true }) do |args|
      asked << args["question"]
      "Question presented to the user."
    end
  end

  def test_an_ends_turn_tool_is_the_runs_last_word
    asked = []
    provider = fake({ tool_calls: [{ name: "ask_user",
                                     arguments: { "question" => "Blue or green?" } }] })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    result = Mistri::Agent.new(provider:, tools: [ask_user(asked)], session:)
                          .run("pick a color")

    assert_predicate result, :completed?
    assert_equal ["Blue or green?"], asked
    assert_equal "Question presented to the user.",
                 session.messages.select(&:tool?).last.text,
                 "the ask is answered in the transcript, ready for the next run"
  end

  def test_the_whole_batch_still_executes_before_the_turn_ends
    ran = []
    log = Mistri::Tool.define("log", "Records.") do
      ran << :log
      "logged"
    end
    provider = fake({ tool_calls: [{ name: "log", arguments: {} },
                                   { name: "ask_user",
                                     arguments: { "question" => "Ready?" } }] })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    Mistri::Agent.new(provider:, tools: [ask_user, log], session:).run("go")

    assert_equal [:log], ran, "a sibling call in the same turn still runs"
    answers = session.messages.select(&:tool?).map(&:text)

    assert_equal 2, answers.length, "every call in the batch is answered"
  end

  def test_a_blocked_ends_turn_call_does_not_end_the_turn
    provider = fake({ tool_calls: [{ name: "ask_user",
                                     arguments: { "question" => "May I?" } }] },
                    { text: "Fine, I will decide myself." })
    gate = ->(call, _context) { "not now" if call.name == "ask_user" }

    result = Mistri::Agent.new(provider:, tools: [ask_user],
                               before_tool: gate).run("go")

    assert_equal "Fine, I will decide myself.", result.text,
                 "a blocked call never executed, so the model keeps the floor"
  end

  def test_an_errored_ends_turn_call_still_hands_away_the_floor
    tools = [
      Mistri::Tool.define("declared", "D.", ends_turn: true) do
        Mistri::ToolResult.new(content: "could not present", error: true)
      end,
      Mistri::Tool.define("raised", "R.", ends_turn: true) { raise "display failed" }
    ]

    tools.each do |tool|
      provider = fake({ tool_calls: [{ name: tool.name, arguments: {} }] })
      agent = Mistri::Agent.new(provider:, tools: [tool])

      result = agent.run("go")

      assert_predicate result, :handed_off?, "ends_turn is structural, not a success claim"
      assert_predicate agent.session.messages.select(&:tool?).last, :tool_error?
      assert_equal 1, provider.requests.length, "the model never mechanically retries the call"
    end
  end

  def test_ends_turn_outranks_a_pending_steer
    provider = fake({ tool_calls: [{ name: "ask_user",
                                     arguments: { "question" => "Which one?" } }] })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    agent = Mistri::Agent.new(provider:, tools: [ask_user], session:)
    steered = false

    result = agent.run("go") do |event|
      next if steered || event.type != :tool_result

      steered = true
      session.steer("actually, make it red")
    end

    assert_predicate result, :completed?
    assert_equal 1, session.pending_inbox.length,
                 "the steer waits for the next run; the floor is the human's"
  end

  def test_an_approved_ends_turn_tool_ends_the_resumed_run
    asked = []
    gated_ask = Mistri::Tool.define("ask_user", "Asks, after approval.",
                                    ends_turn: true, needs_approval: true) do
      asked << :asked
      "Question presented."
    end
    provider = fake({ tool_calls: [{ name: "ask_user", arguments: {} }] })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    agent = Mistri::Agent.new(provider:, tools: [gated_ask], session:)

    first = agent.run("go")

    assert_predicate first, :awaiting_approval?

    session.approve(first.pending.first.id)
    resumed = agent.resume

    assert_predicate resumed, :completed?
    assert_predicate resumed, :handed_off?
    assert_equal [:asked], asked
    refute_nil resumed.message, "the result carries the asking turn's message"
  end

  def test_a_denied_ends_turn_tool_returns_the_floor_to_the_model
    gated_ask = Mistri::Tool.define("ask_user", "Asks, after approval.",
                                    ends_turn: true, needs_approval: true) { "asked" }
    provider = fake({ tool_calls: [{ name: "ask_user", arguments: {} }] },
                    { text: "Understood, moving on." })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    agent = Mistri::Agent.new(provider:, tools: [gated_ask], session:)

    first = agent.run("go")
    session.deny(first.pending.first.id, note: "no interruptions")
    resumed = agent.resume

    assert_equal "Understood, moving on.", resumed.text,
                 "a denied ask never executed, so the run carries on"
  end

  def test_tools_do_not_end_turns_by_default
    provider = fake({ tool_calls: [{ name: "plain", arguments: {} }] },
                    { text: "Kept the floor." })
    plain = Mistri::Tool.define("plain", "Does a thing.") { "done" }

    result = Mistri::Agent.new(provider:, tools: [plain]).run("go")

    refute_predicate plain, :ends_turn?
    refute_predicate result, :handed_off?
    assert_equal "Kept the floor.", result.text
  end

  def test_the_result_says_the_floor_was_handed_off
    provider = fake({ tool_calls: [{ name: "ask_user",
                                     arguments: { "question" => "Proceed?" } }] })

    result = Mistri::Agent.new(provider:, tools: [ask_user]).run("go")

    assert_predicate result, :handed_off?, "hosts route on this instead of sniffing messages"
    assert_predicate result, :completed?
  end

  def test_task_mode_preserves_the_handoff_instead_of_revalidating
    schema = { "type" => "object", "properties" => { "answer" => { "type" => "string" } },
               "required" => ["answer"] }
    # One scripted turn and none to spare: if task mode tried to fix the
    # "invalid" JSON, the provider would raise; if it burned the fix budget,
    # SchemaError would. Neither may happen while a human holds the floor.
    provider = fake({ tool_calls: [{ name: "ask_user",
                                     arguments: { "question" => "Which city?" } }] })

    result = Mistri::Agent.new(provider:, tools: [ask_user])
                          .task("Find the HQ.", schema: schema, fixes: 0)

    assert_predicate result, :handed_off?
    assert_nil result.output, "no validated value yet; ask again once the answer arrives"
  end
end
