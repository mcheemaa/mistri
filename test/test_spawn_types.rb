# frozen_string_literal: true

require_relative "test_helper"

# Typed workers and the headcount: a spawn type is a host-curated
# Definition (validated at construction, never mid-spawn), general-purpose
# stays the composable default, and max_children answers in band.
class TestSpawnTypes < Minitest::Test
  def teardown
    Mistri.locks = nil
  end

  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def archive = Mistri::Tool.define("archive", "Facts lookup.") { "founded 1912" }

  def researcher_type(model: nil)
    config = { "role" => "Researcher", "tools" => ["archive"] }
    config["model"] = model if model
    Mistri::Definition.new(name: "researcher", config: config,
                           body: "You research companies and report tersely.")
  end

  def spawn_call(arguments)
    fake({ tool_calls: [{ name: "spawn_agent", arguments: arguments }] },
         { text: "Parent done." })
  end

  def test_a_typed_worker_takes_its_prompt_tools_and_appends_instructions
    child_fake = fake({ text: "Report: founded 1912." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [archive],
                                     types: { "researcher" => researcher_type })
    parent_fake = spawn_call({ "name" => "Corgi", "type" => "researcher",
                               "task" => "when was it founded?",
                               "instructions" => "Focus on the founding year only." })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:).run("go")

    system = child_fake.requests.first[:options][:system]

    assert_match(/You research companies/, system)
    assert_match(/Focus on the founding year only\./, system)
    sent_tools = child_fake.requests.first[:options][:tools].map { |tool| tool[:name] }

    assert_equal ["archive"], sent_tools
    assert_equal :done, session.children.first.status
  end

  def test_an_empty_typed_definition_grants_no_pool_tools
    unused = Mistri::Tool.define("danger", "Must remain unavailable.") { "ran" }
    definition = Mistri::Definition.new(name: "observer", config: {}, body: "Observe only.")
    child_fake = fake({ text: "Observed." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [unused],
                                     types: { "observer" => definition })
    parent_fake = spawn_call({ "name" => "Corgi", "type" => "observer", "task" => "look" })

    Mistri::Agent.new(provider: parent_fake, tools: [spawn]).run("go")

    assert_empty child_fake.requests.first[:options][:tools]
  end

  def test_an_explicit_empty_list_overrides_typed_defaults
    child_fake = fake({ text: "No tools needed." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [archive],
                                     types: { "researcher" => researcher_type })
    parent_fake = spawn_call({ "name" => "Corgi", "type" => "researcher", "task" => "think",
                               "tools" => [] })

    Mistri::Agent.new(provider: parent_fake, tools: [spawn]).run("go")

    assert_empty child_fake.requests.first[:options][:tools]
  end

  def test_an_explicit_empty_list_grants_a_general_worker_no_tools
    child_fake = fake({ text: "No tools needed." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [archive])
    parent_fake = spawn_call({ "name" => "Corgi", "task" => "think",
                               "instructions" => "Think only.", "tools" => [] })

    Mistri::Agent.new(provider: parent_fake, tools: [spawn]).run("go")

    assert_empty child_fake.requests.first[:options][:tools]
  end

  def test_spawner_owns_its_tool_pool_and_model_allowlist
    declared = archive
    pool = [declared]
    model_name = +"host-model-v1"
    models = [model_name]
    child_fake = fake({ text: "done" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: pool, models: models)

    pool.clear
    models.clear
    model_name.replace("tampered")
    parent_fake = spawn_call({ "name" => "Corgi", "task" => "work",
                               "instructions" => "Use the declared tools." })

    Mistri::Agent.new(provider: parent_fake, tools: [spawn]).run("go")

    sent = child_fake.requests.first[:options][:tools].map { |tool| tool.fetch(:name) }

    assert_equal ["archive"], sent
    assert_equal ["host-model-v1"],
                 spawn.input_schema.dig("properties", "model", "enum")
  end

  def test_duplicate_model_selected_tools_are_refused_before_a_child_exists
    child_fake = fake({ text: "never" })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [archive])
    parent_fake = spawn_call({ "name" => "Corgi", "task" => "work",
                               "instructions" => "Work.",
                               "tools" => %w[archive archive] })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    Mistri::Agent.new(provider: parent_fake, tools: [spawn], session: session).run("go")

    result = session.messages.select(&:tool?).last

    assert_predicate result, :tool_error?
    assert_match(/duplicate/, result.text)
    assert_empty session.children
    assert_empty child_fake.requests
  end

  def test_duplicate_model_allowlist_entries_fail_at_construction
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake, models: %w[gpt-5-nano gpt-5-nano])
    end

    assert_match(/duplicate model names/, error.message)
  end

  def test_a_general_purpose_worker_without_instructions_answers_in_band
    spawn = Mistri::SubAgent.spawner(provider: fake)
    parent_fake = spawn_call({ "name" => "Husky", "task" => "do something" })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    result = Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:).run("go")

    assert_equal "Parent done.", result.text, "the parent reads the refusal and continues"
    tool_message = session.messages.select(&:tool?).last

    assert_includes tool_message.text, "$.instructions is required"
    assert_predicate tool_message, :tool_error?
    assert_empty session.children, "no child is born from a refused spawn"
  end

  def test_an_unknown_type_answers_with_the_menu
    spawn = Mistri::SubAgent.spawner(provider: fake, tools: [archive],
                                     types: { "researcher" => researcher_type })
    parent_fake = spawn_call({ "name" => "Beagle", "type" => "designer", "task" => "draw" })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:).run("go")

    tool_message = session.messages.select(&:tool?).last

    assert_includes tool_message.text, "$.type must match enum"
    assert_predicate tool_message, :tool_error?
  end

  def test_a_type_with_placeholders_fails_at_construction
    holey = Mistri::Definition.new(name: "greeter", config: {},
                                   body: "Greet {first_name} warmly.")

    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake, types: { "greeter" => holey })
    end

    assert_match(/cannot be a spawn type/, error.message)
  end

  def test_a_type_declaring_tools_outside_the_pool_fails_at_construction
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake, tools: [],
                               types: { "researcher" => researcher_type })
    end

    assert_match(/declares tools the pool lacks: archive/, error.message)
  end

  def test_the_built_in_type_name_is_reserved
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::SubAgent.spawner(provider: fake,
                               types: { "general-purpose" => researcher_type })
    end

    assert_match(/built-in type/, error.message)
  end

  def test_max_children_refuses_in_band_and_freed_slots_reopen
    Mistri.locks = Mistri::Locks::Memory.new
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    3.times do |i|
      child = Mistri::Session.new(store:)
      session.append("subagent", "name" => "W#{i}", "session_id" => child.id)
      Mistri.locks.acquire(Mistri::Child.lease_key(child.id), ttl: 60)
    end
    spawn = Mistri::SubAgent.spawner(provider: fake({ text: "hi" }), max_children: 3)
    parent_fake = spawn_call({ "name" => "Extra", "task" => "t", "instructions" => "You help." })

    Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:).run("go")

    refusal = session.messages.select(&:tool?).last

    assert_match(/already have 3 workers running/, refusal.text)
    assert_equal 3, session.children.length, "the refused spawn creates nothing"

    # One worker finishes; the slot reopens.
    finished = session.children.first
    Mistri.locks.release(Mistri::Child.lease_key(finished.session_id))
    Mistri::Session.new(store:, id: finished.session_id)
                   .append(Mistri::Child::TERMINAL, "status" => "done", "report" => "ok")
    retry_fake = spawn_call({ "name" => "Extra", "task" => "t", "instructions" => "You help." })

    Mistri::Agent.new(provider: retry_fake, tools: [spawn], session:).run("go")

    assert_equal 4, session.children.length
    assert_equal :done, session.children.last.status
  end

  def test_symbol_keyed_types_resolve_like_string_keyed_ones
    child_fake = fake({ text: "Report ready." })
    spawn = Mistri::SubAgent.spawner(provider: child_fake, tools: [archive],
                                     types: { researcher: researcher_type })
    parent_fake = spawn_call({ "name" => "Corgi", "type" => "researcher", "task" => "go" })
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)

    Mistri::Agent.new(provider: parent_fake, tools: [spawn], session:).run("go")

    assert_equal :done, session.children.first.status,
                 "the wire speaks strings; a symbol-keyed registry must still resolve"
  end

  def test_pack_bundles_the_spawner_with_the_console
    names = Mistri::SubAgent.pack(provider: fake).map(&:name)

    assert_equal %w[spawn_agent list_agents read_agent steer_agent stop_agent], names
  end
end
