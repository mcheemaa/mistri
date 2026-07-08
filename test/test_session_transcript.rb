# frozen_string_literal: true

require_relative "test_helper"

# Session#transcript: the readable view of a run. Images strip, and with
# include_children every sub-agent's log splices in after its link entry,
# origin-tagged exactly like the live stream, so a UI rebuilding from the
# store sees the lanes it saw live.
class TestSessionTranscript < Minitest::Test
  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def test_the_transcript_strips_images_but_the_raw_log_keeps_them
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    image = Mistri::Content::Image.from_bytes("png!", mime_type: "image/png")
    session.append_message(Mistri::Message.user(["look", image]))

    rendered = session.transcript.first.dig("message", "content").last

    assert rendered["omitted"]
    refute rendered.key?("data")
    raw = session.entries.first.dig("message", "content").last

    assert raw.key?("data"), "the raw log is untouched"
  end

  def test_child_entries_splice_in_after_their_link_origin_tagged
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    researcher = Mistri::SubAgent.new(name: "researcher", description: "Looks things up.",
                                      provider: fake({ text: "Their HQ is in Boise." }))
    parent = fake({ tool_calls: [{ name: "researcher",
                                   arguments: { "task" => "find the HQ" } }] },
                  { text: "It is Boise." })

    Mistri::Agent.new(provider: parent, tools: [researcher.tool], session:).run("go")

    transcript = session.transcript(include_children: true)
    link_at = transcript.index { |entry| entry["type"] == "subagent" }
    child_id = transcript[link_at]["session_id"]
    spliced = transcript.select { |entry| entry["origin"] }

    refute_empty spliced, "the child's entries are in the parent's transcript"
    spliced.each { |entry| assert_equal "researcher##{child_id[0, 8]}", entry["origin"] }
    assert_operator link_at, :<, transcript.index { |entry| entry["origin"] },
                    "the lane opens where the link sits"
    texts = spliced.filter_map { |entry| entry.dig("message", "content", 0, "text") }

    assert_includes texts.join("\n"), "Their HQ is in Boise."
    assert(session.transcript.none? { |entry| entry["origin"] },
           "without include_children the view stays flat")
  end

  def test_nested_lanes_join_origins_like_the_live_stream
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    grandchild = Mistri::Session.new(store:)
    grandchild.append_message(Mistri::Message.user("deep work"))
    child = Mistri::Session.new(store:)
    child.append("subagent", "name" => "writer", "session_id" => grandchild.id)
    session.append("subagent", "name" => "researcher", "session_id" => child.id)

    transcript = session.transcript(include_children: true)
    deep = transcript.find { |entry| entry.dig("message", "content", 0, "text") == "deep work" }

    assert_equal "researcher##{child.id[0, 8]}>writer##{grandchild.id[0, 8]}",
                 deep["origin"]
    nested_link = transcript.find { |entry| entry["name"] == "writer" }

    assert_equal "researcher##{child.id[0, 8]}", nested_link["origin"],
                 "the nested link entry itself sits in its parent's lane"
  end

  def test_a_running_childs_progress_so_far_is_included
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    child = Mistri::Session.new(store:)
    session.append("subagent", "name" => "scout", "session_id" => child.id)
    child.append(Mistri::Child::STARTED, {})
    child.append_message(Mistri::Message.user("half way"))

    spliced = session.transcript(include_children: true).select { |entry| entry["origin"] }

    assert_equal 2, spliced.length, "a live lane renders its progress so far"
  end

  def test_repeated_and_self_links_render_but_never_expand_twice
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    child = Mistri::Session.new(store:)
    child.append_message(Mistri::Message.user("once"))
    session.append("subagent", "name" => "echo", "session_id" => child.id)
    session.append("subagent", "name" => "echo", "session_id" => child.id)
    session.append("subagent", "name" => "loop", "session_id" => session.id)

    transcript = session.transcript(include_children: true)
    links = transcript.count { |entry| entry["type"] == "subagent" }
    lanes = transcript.count { |entry| entry["origin"] }

    assert_equal 3, links
    assert_equal 1, lanes, "the child expanded exactly once and the self-link not at all"
  end

  def test_a_link_to_a_session_with_no_entries_renders_just_the_link
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    session.append("subagent", "name" => "ghost", "session_id" => "never-ran")

    transcript = session.transcript(include_children: true)

    assert_equal 1, transcript.length
    assert_equal "ghost", transcript.first["name"]
  end

  def test_transcript_origins_match_what_the_stream_emitted
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    researcher = Mistri::SubAgent.new(name: "researcher", description: "Looks things up.",
                                      provider: fake({ text: "Found it." }))
    parent = fake({ tool_calls: [{ name: "researcher", arguments: { "task" => "look" } }] },
                  { text: "Done." })
    streamed = []

    Mistri::Agent.new(provider: parent, tools: [researcher.tool], session:).run("go") do |event|
      streamed << event.origin if event.origin
    end

    replayed = session.transcript(include_children: true)
                      .filter_map { |entry| entry["origin"] }

    assert_equal streamed.uniq.sort, replayed.uniq.sort,
                 "a reload rebuilds exactly the lanes the stream showed"
  end
end
