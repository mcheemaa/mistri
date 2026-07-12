# frozen_string_literal: true

require_relative "test_helper"

# The children registry: every spawned sub-agent stays visible through
# Session#children as a Child window onto its own session, with a status
# derived from the store alone and a terminal entry as the completion
# contract.
class TestChildren < Minitest::Test
  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def spawn_once(store, child_provider, name: "Magpie")
    spawn = Mistri::SubAgent.spawner(provider: child_provider)
    parent = fake({ tool_calls: [{ name: "spawn_agent",
                                   arguments: { "name" => name, "task" => "find the answer",
                                                "instructions" => "You are a finder." } }] },
                  { text: "All done." })
    session = Mistri::Session.new(store:)
    Mistri::Agent.new(provider: parent, tools: [spawn], session:).run("go")
    session
  end

  def test_a_finished_child_reads_done_with_its_report
    store = Mistri::Stores::Memory.new
    session = spawn_once(store, fake({ text: "The answer is 42." }))

    children = session.children

    assert_equal 1, children.length
    child = children.first

    assert_equal "Magpie", child.name
    assert_equal :done, child.status
    assert_equal "The answer is 42.", child.report
    assert_equal "Magpie", child.to_h["name"]
  end

  def test_a_child_that_crashes_still_ends_with_a_failed_terminal
    store = Mistri::Stores::Memory.new
    # A fake with no scripted turns raises inside the child's first turn.
    session = spawn_once(store, fake)

    child = session.children.first

    assert_equal :failed, child.status
    assert_nil child.report
    terminal = Mistri::Session.new(store:, id: child.session_id).entries.last

    assert_equal Mistri::Child::TERMINAL, terminal["type"]
    assert_match(/no scripted turns/, terminal["error"])
  end

  def test_a_duplicate_spawn_pool_fails_at_construction
    duplicate = Mistri::Tool.define("lookup", "Looks up.") { "42" }
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake, tools: [duplicate, duplicate])
    end

    assert_match(/duplicate tool names/, error.message)
  end

  def test_status_derives_from_hand_written_entries
    store = Mistri::Stores::Memory.new
    parent = Mistri::Session.new(store:)
    running = Mistri::Session.new(store:)
    stopped = Mistri::Session.new(store:)
    parent.append("subagent", "name" => "Wren", "session_id" => running.id)
    parent.append("subagent", "name" => "Heron", "session_id" => stopped.id)
    stopped.append(Mistri::Child::TERMINAL, "status" => "stopped")

    statuses = parent.children.to_h { |child| [child.name, child.status] }

    assert_equal({ "Wren" => :running, "Heron" => :stopped }, statuses)
  end

  def test_say_queues_a_steer_on_the_child_session
    store = Mistri::Stores::Memory.new
    session = spawn_once(store, fake({ text: "Working." }))
    child = session.children.first

    child.say("Also check the pricing page")

    pending = Mistri::Session.new(store:, id: child.session_id).pending_steers

    assert_equal 1, pending.length
    assert_equal "Also check the pricing page",
                 Mistri::Message.from_h(pending.first["message"]).text
  end

  def test_transcript_tails_and_strips_image_bytes
    store = Mistri::Stores::Memory.new
    parent = Mistri::Session.new(store:)
    child = Mistri::Session.new(store:)
    parent.append("subagent", "name" => "Finch", "session_id" => child.id)
    child.append_message(Mistri::Message.user("look at this"))
    child.append("message", "message" => {
                   "role" => "tool", "tool_call_id" => "c1", "tool_name" => "browser",
                   "content" => [{ "data" => "AAAA", "mime_type" => "image/png" }]
                 })

    transcript = parent.children.first.transcript(tail: 1)

    assert_equal 1, transcript.length
    block = transcript.first.dig("message", "content").first

    refute block.key?("data"), "image bytes must not ride along"
    assert block["omitted"]
    assert_equal "image/png", block["mime_type"]
  end
end
