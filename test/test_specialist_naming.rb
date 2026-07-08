# frozen_string_literal: true

require_relative "test_helper"

# A named specialist is a role; each run of it can carry its own name, so
# two parallel researchers read as Corgi and Beagle in lanes, lists, and
# links instead of "researcher" twice.
class TestSpecialistNaming < Minitest::Test
  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def researcher(provider)
    Mistri::SubAgent.new(name: "researcher", description: "Looks things up.",
                         provider: provider)
  end

  def run_with(arguments)
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    parent = fake({ tool_calls: [{ name: "researcher", arguments: arguments }] },
                  { text: "Done." })
    origins = []
    Mistri::Agent.new(provider: parent, tools: [researcher(fake({ text: "Found." })).tool],
                      session:).run("go") do |event|
      origins << event.origin if event.origin
    end
    [session, origins]
  end

  def test_a_run_can_carry_its_own_name
    session, origins = run_with({ "task" => "find the HQ", "name" => "Corgi" })
    child = session.children.first

    assert_equal "Corgi", child.name
    assert origins.all? { |origin| origin.start_with?("Corgi#") },
           "the lane is the run's name, not the role's: #{origins.uniq}"
  end

  def test_an_unnamed_run_reads_as_the_specialist
    session, origins = run_with({ "task" => "find the HQ" })

    assert_equal "researcher", session.children.first.name
    assert origins.all? { |origin| origin.start_with?("researcher#") },
           "unexpected lane: #{origins.uniq}"
  end

  def test_hostile_names_are_made_safe_for_origins
    session, = run_with({ "task" => "t", "name" => "Cor gi>#hash" })

    assert_equal "Cor-gi-hash", session.children.first.name
  end

  def test_a_blank_name_falls_back
    assert_equal "researcher", Mistri::SubAgent.sanitize_label("  ", fallback: "researcher")
    assert_equal "spawn", Mistri::SubAgent.sanitize_label(nil, fallback: "spawn")
  end
end
