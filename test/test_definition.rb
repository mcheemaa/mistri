# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Agent definitions: frontmatter markdown in, config and a rendered prompt
# out. The gem reads the file; the host owns the vocabulary.
class TestDefinition < Minitest::Test
  def write(content)
    path = File.join(@dir, "trip_planner.md")
    File.write(path, content)
    path
  end

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_loads_config_from_frontmatter_and_the_prompt_from_the_body
    definition = Mistri::Definition.load(write(<<~MD))
      ---
      role: Trip Planner
      model: claude-opus-4-8
      tools:
        - search_flights
        - book_hotel
      ---
      You plan trips end to end. Address the traveler as {first_name}.
    MD

    assert_equal "trip_planner", definition.name
    assert_equal "claude-opus-4-8", definition.model
    assert_equal "Trip Planner", definition.role
    assert_equal %w[search_flights book_hotel], definition.tool_names
    assert_equal({ "search_flights" => {}, "book_hotel" => {} }, definition.tools)
    assert_equal "You plan trips end to end. Address the traveler as Dana.",
                 definition.render(first_name: "Dana")
  end

  def test_the_map_form_carries_per_tool_options_in_the_hosts_vocabulary
    definition = Mistri::Definition.load(write(<<~MD))
      ---
      tools:
        book_hotel:
          gate: budget-approval
        search_flights:
      ---
      Prompt.
    MD

    assert_equal({ "book_hotel" => { "gate" => "budget-approval" }, "search_flights" => {} },
                 definition.tools)
  end

  def test_extra_frontmatter_keys_ride_through_config
    definition = Mistri::Definition.load(write(<<~MD))
      ---
      itinerary_style: relaxed
      ---
      Prompt.
    MD

    assert_equal "relaxed", definition.config["itinerary_style"]
  end

  def test_an_unfilled_placeholder_fails_loudly_and_nil_renders_empty
    definition = Mistri::Definition.load(write(<<~MD))
      ---
      role: A
      ---
      Hello {first_name}.{scope_note}
    MD

    error = assert_raises(Mistri::ConfigurationError) { definition.render(first_name: "D") }
    assert_includes error.message, "scope_note"
    assert_equal "Hello D.", definition.render(first_name: "D", scope_note: nil)
  end

  def test_files_without_frontmatter_fail_loudly
    path = write("just a prompt, no frontmatter")

    assert_raises(Mistri::ConfigurationError) { Mistri::Definition.load(path) }
  end
end
