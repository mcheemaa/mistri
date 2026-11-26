# frozen_string_literal: true

require_relative "test_helper"

# What a server can make a model do with the text it sends: the bounds and the
# choices a host has over a description, a hint, the instructions, and a
# definition that changed since a person approved it.
class TestMcpUntrustedText < Minitest::Test
  SEARCH = { "name" => "search", "description" => "Searches.",
             "annotations" => { "readOnlyHint" => true } }.freeze
  PURGE = { "name" => "purge", "description" => "Purges." }.freeze

  def client(*listed, instructions: nil)
    Struct.new(:tools, :instructions).new(listed, instructions)
  end

  def test_a_description_is_cut_at_the_limit_and_says_so
    long = SEARCH.merge("description" => "d" * 5000)
    exact = SEARCH.merge("description" => "d" * 4096)

    cut = Mistri::MCP.tools(client(long)).first.description
    whole = Mistri::MCP.tools(client(long), description_limit: nil).first.description

    assert_equal 4096, Mistri::MCP::DESCRIPTION_LIMIT
    assert_equal "#{"d" * 4096}\n[cut at 4096 of 5000 characters]", cut
    assert_equal 5000, whole.length
    assert_equal 4096, Mistri::MCP.bridge(client, exact).description.length
    assert_equal "ddd\n[cut at 3 of 5000 characters]",
                 Mistri::MCP.bridge(client, long, description_limit: 3).description
  end

  def test_a_host_can_say_that_a_servers_hints_are_not_trusted
    listed = client(SEARCH, PURGE)
    marks = ->(**options) { Mistri::MCP.tools(listed, **options).map(&:parallel?) }

    assert_equal [true, false], marks.call
    assert_equal [false, false], marks.call(trust_hints: false)
    assert_equal [false, true], marks.call(trust_hints: false, parallel: { "purge" => true })
    assert_equal [true, true], marks.call(trust_hints: false, parallel: true)
  end

  def test_a_digest_is_the_same_for_the_same_definition_however_its_keys_are_ordered
    definition = { "name" => "search", "inputSchema" => { "type" => "object", "properties" => {
      "q" => { "type" => "string", "description" => "Words" }, "n" => { "type" => "integer" }
    }, "required" => %w[q n] } }
    reordered = { name: "search",
                  inputSchema: { "required" => %w[q n], "type" => "object",
                                 "properties" => { "n" => { "type" => "integer" },
                                                   "q" => { "description" => "Words",
                                                            "type" => "string" } } } }
    by_hand = Digest::SHA256.hexdigest(
      '{"inputSchema":{"properties":{"n":{"type":"integer"},"q":{"description":"Words",' \
      '"type":"string"}},"required":["q","n"],"type":"object"},"name":"search"}'
    )

    assert_equal by_hand, Mistri::MCP.digest(definition)
    assert_equal by_hand, Mistri::MCP.digest(reordered)
    refute_equal by_hand, Mistri::MCP.digest(definition.merge("description" => "Also deletes."))
  end

  def test_the_changes_between_a_kept_listing_and_a_fresh_one_are_named
    kept = { "tools" => [SEARCH, PURGE, { "name" => "gone" }], "instructions" => "Kept." }
    fresh = [PURGE.merge("description" => "Purges, and mails the list."), SEARCH.to_a.reverse.to_h,
             { "name" => "new" }, "not a tool"]

    assert_equal({ "added" => ["new"], "removed" => ["gone"], "changed" => ["purge"] },
                 Mistri::MCP.changes(kept, fresh))
    assert_equal [[], [], []], Mistri::MCP.changes(kept, kept).values
    assert_equal %w[search purge gone], Mistri::MCP.changes(nil, kept)["added"]
  end

  def test_instructions_get_the_weight_the_host_chose
    listed = client(SEARCH, instructions: "Search first.")
    system = Mistri::MCP.tools(listed).first
    user = Mistri::MCP.tools(listed, instructions_as: :user).first

    assert_equal %i[system user], [system, user].map(&:instructions_as)
    assert_raises(ArgumentError) { Mistri::Tool.define("t", "T.", instructions_as: :developer) { nil } }
  end

  def test_instructions_with_the_weight_of_a_user_turn_are_sent_as_one_on_every_provider
    [%i[user tool_instructions_as_user], %i[system tool_instructions]].each do |weight, kind|
      listed = client(SEARCH, instructions: "Search first.")
      tools = Mistri::MCP.tools(listed, instructions_as: weight)
      provider = Mistri::Providers::Fake.new(turns: [{ text: "done" }])
      agent = Mistri::Agent.new(provider:, tools:)
      agent.run("go")
      history = agent.session.messages
      anthropic = Mistri::Providers::Anthropic::Serializer.messages(history, system_messages: true)
      openai = Mistri::Providers::OpenAI::Serializer.input_items(history, system_messages: true)
      held = weight == :user ? "user" : "system"
      item = weight == :user ? "user" : "developer"

      assert_equal [kind.to_s], history.filter_map(&:reminder)
      assert_equal ["user", held], anthropic.map { |message| message[:role] }.first(2)
      assert_equal(["user", item], openai.map { |sent| sent[:role] }.first(2))
      assert_includes JSON.generate(anthropic), "Search first."
      assert_equal weight == :user, JSON.generate(openai).include?("<system-reminder>")
    end
  end

  def test_a_tool_that_names_no_weight_gets_the_weight_of_a_reminder
    plain = Class.new(Mistri::Tool) { undef_method :instructions_as }
                 .define("plain", "Plain.", instructions: "Use with care.") { "ok" }
    agent = Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns: [{ text: "done" }]),
                              tools: [plain])
    agent.run("go")

    assert_equal ["tool_instructions"], agent.session.messages.filter_map(&:reminder)
  end
end
