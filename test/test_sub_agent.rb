# frozen_string_literal: true

require_relative "test_helper"

# Sub-agents: delegation with a clean context. Children run on their own
# sessions on the caller's store, stream with origin attribution, and answer
# the parent in band whatever happens.
class TestSubAgent < Minitest::Test
  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def test_a_named_specialist_answers_with_a_linked_child_transcript
    store = Mistri::Stores::Memory.new
    child_fake = fake({ text: "Founded in 1912." })
    researcher = Mistri::SubAgent.new(name: "researcher", description: "Answers questions.",
                                      provider: child_fake)
    parent_fake = fake({ tool_calls: [{ name: "researcher",
                                        arguments: { "task" => "founding year?" } }] },
                       { text: "It was 1912." })
    session = Mistri::Session.new(store:)
    events = []

    result = Mistri::Agent.new(provider: parent_fake, tools: [researcher.tool], session:)
                          .run("when was it founded") { |e| events << e }

    assert_equal "It was 1912.", result.text

    tool_message = session.messages.select(&:tool?).last

    assert_equal "Founded in 1912.", tool_message.text
    assert_equal "researcher", tool_message.ui["agent"]

    child = Mistri::Session.new(store:, id: tool_message.ui["session_id"])

    assert_equal "founding year?", child.messages.first.text, "the child transcript persists"

    entry = session.entries.find { |e| e["type"] == "subagent" }

    assert_equal tool_message.ui["session_id"], entry["session_id"]

    origins = events.filter_map(&:origin).uniq

    assert_equal 1, origins.length
    assert_match(/\Aresearcher#\h{8}\z/, origins.first)
    assert(events.any? { |e| e.origin.nil? && e.type == :done }, "parent events stay untagged")
  end

  def test_the_spawner_runs_a_child_with_written_instructions_and_a_tool_subset
    used = []
    lookup = Mistri::Tool.define("lookup", "Looks up.") do
      used << :lookup
      "42"
    end
    search = Mistri::Tool.define("search", "Searches.") { "irrelevant" }
    child_fake = fake({ tool_calls: [{ name: "lookup", arguments: {} }] },
                      { text: "The answer is 42." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [lookup, search])
    parent_fake = fake({ tool_calls: [{ name: "spawn_agent",
                                        arguments: { "task" => "find the answer",
                                                     "instructions" => "You are a finder.",
                                                     "tools" => ["lookup"] } }] },
                       { text: "done" })
    agent = Mistri::Agent.new(provider: parent_fake, tools: [spawn])

    agent.run("go")

    child_request = child_fake.requests.first

    assert_equal "You are a finder.", child_request[:options][:system]
    assert_equal ["lookup"], child_request[:options][:tools].map { |t| t[:name] },
                 "the child got only the granted subset, and never spawn_agent"
    assert_equal [:lookup], used
  end

  def test_an_unknown_tool_grant_answers_in_band
    spawn = Mistri::SubAgent.spawner(provider: fake,
                                     tools: [Mistri::Tool.define("lookup", "L.") { "x" }])
    parent_fake = fake({ tool_calls: [{ name: "spawn_agent",
                                        arguments: { "task" => "t", "instructions" => "i",
                                                     "tools" => ["nope"] } }] },
                       { text: "ok" })
    agent = Mistri::Agent.new(provider: parent_fake, tools: [spawn])

    agent.run("go")

    answer = agent.session.messages.select(&:tool?).last.text

    assert_includes answer, "$.tools[0] must match enum"
  end

  def test_parallel_fan_out_runs_both_children
    child_fake = fake({ text: "alpha" }, { text: "beta" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake)
    parent_fake = fake({ tool_calls: [
                         { name: "spawn_agent",
                           arguments: { "task" => "a", "instructions" => "i" } },
                         { name: "spawn_agent",
                           arguments: { "task" => "b", "instructions" => "i" } }
                       ] },
                       { text: "synthesized" })
    agent = Mistri::Agent.new(provider: parent_fake, tools: [spawn])

    result = agent.run("fan out")

    assert_equal "synthesized", result.text
    assert_equal %w[alpha beta], agent.session.messages.select(&:tool?).map(&:text).sort
    assert_equal(2, agent.session.entries.count { |e| e["type"] == "subagent" })
  end

  def test_statically_gated_tools_are_refused_at_construction
    gated = Mistri::Tool.define("send", "S.", needs_approval: true) { "x" }

    assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.new(name: "a", description: "d", provider: fake, tools: [gated])
    end
    assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake, tools: [gated])
    end
  end

  def test_a_runtime_suspended_child_is_denied_and_reported
    risky = Mistri::Tool.define("pay", "Pays.",
                                needs_approval: ->(args) { args["amount"].to_i > 10 },
                                schema: -> { integer :amount, "Amount", required: true }) { "paid" }
    child_fake = fake({ tool_calls: [{ name: "pay", arguments: { "amount" => 50 } }] })
    worker = Mistri::SubAgent.new(name: "worker", description: "Works.",
                                  provider: child_fake, tools: [risky])
    parent_fake = fake({ tool_calls: [{ name: "worker", arguments: { "task" => "pay 50" } }] },
                       { text: "understood" })
    store = Mistri::Stores::Memory.new
    agent = Mistri::Agent.new(provider: parent_fake, tools: [worker.tool],
                              session: Mistri::Session.new(store:))

    result = agent.run("go")

    assert_predicate result, :completed?

    answer = agent.session.messages.select(&:tool?).last

    assert_includes answer.text, "cannot wait"
    assert_predicate answer, :tool_error?

    child = Mistri::Session.new(store:, id: answer.ui["session_id"])

    assert_empty child.open_approvals, "the orphaned approval is denied and settled"
    denial = child.messages.select(&:tool?).last

    assert_includes denial.text, "cannot pause"
    assert_predicate denial, :tool_error?
  end

  def test_gating_the_delegation_itself_suspends_the_parent
    child_fake = fake
    researcher = Mistri::SubAgent.new(name: "researcher", description: "R.",
                                      provider: child_fake, needs_approval: true)
    parent_fake = fake({ tool_calls: [{ name: "researcher", arguments: { "task" => "t" } }] })

    result = Mistri::Agent.new(provider: parent_fake, tools: [researcher.tool]).run("go")

    assert_predicate result, :awaiting_approval?
    assert_equal "researcher", result.pending.first.name
    assert_empty child_fake.requests, "the child never ran without approval"
  end

  def test_a_schemad_specialist_returns_validated_json
    schema = { type: "object", properties: { "year" => { type: "integer" } },
               required: ["year"] }
    child_fake = fake({ text: '{"year":1912}' })
    extractor = Mistri::SubAgent.new(name: "extractor", description: "Extracts.",
                                     provider: child_fake, schema: schema)
    parent_fake = fake({ tool_calls: [{ name: "extractor", arguments: { "task" => "year?" } }] },
                       { text: "done" })
    agent = Mistri::Agent.new(provider: parent_fake, tools: [extractor.tool])

    agent.run("go")

    assert_equal '{"year":1912}', agent.session.messages.select(&:tool?).last.text
    assert_equal Mistri::Schema.strict(schema),
                 child_fake.requests.first[:options][:output_schema]
  end

  def test_an_errored_child_reports_in_band
    boom = Mistri::SubAgent.new(name: "boom", description: "B.",
                                provider: fake({ error: "exploded" }))
    parent_fake = fake({ tool_calls: [{ name: "boom", arguments: { "task" => "t" } }] },
                       { text: "noted" })
    agent = Mistri::Agent.new(provider: parent_fake, tools: [boom.tool])

    result = agent.run("go")

    assert_predicate result, :completed?
    answer = agent.session.messages.select(&:tool?).last

    assert_includes answer.text, "failed"
    assert_predicate answer, :tool_error?
  end

  def test_child_models_come_only_from_the_host_allowlist
    spawn = Mistri::SubAgent.spawner(provider: fake({ text: "hi" }),
                                     models: ["claude-haiku-4-5-20251001"])
    parent_fake = fake({ tool_calls: [{ name: "spawn_agent",
                                        arguments: { "task" => "t", "instructions" => "i",
                                                     "model" => "gpt-5.2-mini" } }] },
                       { text: "ok" })
    agent = Mistri::Agent.new(provider: parent_fake, tools: [spawn])

    agent.run("go")

    answer = agent.session.messages.select(&:tool?).last.text

    assert_includes answer, "$.model must match enum"
  end

  def test_without_an_allowlist_the_spawner_offers_no_model_choice
    spawn = Mistri::SubAgent.spawner(provider: fake)
    properties = spawn.spec[:input_schema]["properties"]

    refute properties.key?("model"), "no allowlist means no model surface at all"
  end

  def test_the_model_names_its_worker_across_origins_and_the_link
    store = Mistri::Stores::Memory.new
    spawn = Mistri::SubAgent.spawner(provider: fake({ text: "$8 a seat" }))
    parent_fake = fake({ tool_calls: [{ name: "spawn_agent",
                                        arguments: { "name" => "pricing-scout",
                                                     "task" => "t",
                                                     "instructions" => "i" } }] },
                       { text: "done" })
    session = Mistri::Session.new(store:)
    events = []

    Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:)
                 .run("go") { |e| events << e }

    origins = events.filter_map(&:origin).uniq

    assert_equal 1, origins.length
    assert_match(/\Apricing-scout#\h{8}\z/, origins.first)

    link = session.messages.select(&:tool?).last.ui

    assert_equal "pricing-scout", link["agent"]
    assert_equal "pricing-scout",
                 session.entries.find { |e| e["type"] == "subagent" }["name"]
  end

  def test_worker_names_sanitize_for_the_origin_channel
    calls = [{ "name" => "  Pricing # Scout > v2 ", "task" => "t", "instructions" => "i" },
             { "task" => "t", "instructions" => "i" }]
    calls.each_with_index do |arguments, index|
      spawn = Mistri::SubAgent.spawner(provider: fake({ text: "ok" }))
      parent_fake = fake({ tool_calls: [{ name: "spawn_agent", arguments: }] },
                         { text: "done" })
      agent = Mistri::Agent.new(provider: parent_fake, tools: [spawn])
      origins = []

      agent.run("go") { |e| origins << e.origin if e.origin }

      expected = index.zero? ? "Pricing-Scout-v2" : "spawn"

      assert_match(/\A#{expected}#\h{8}\z/, origins.first)
    end
  end

  def test_the_model_surface_names_the_default_child_model
    spawn = Mistri::SubAgent.spawner(provider: fake, models: ["claude-haiku-4-5-20251001"])
    properties = spawn.spec[:input_schema]["properties"]

    assert properties.key?("name"), "the worker name surface exists"
    assert_includes properties["model"]["description"], "fake-1",
                    "the default model is named, so the choice is informed"
  end

  def test_strict_lambda_handlers_still_receive_one_argument
    handler = ->(args) { "got #{args["x"]}" }
    tool = Mistri::Tool.new(name: "t", description: "d", &handler)

    assert_equal "got 1", tool.call({ "x" => 1 })
  end
end
