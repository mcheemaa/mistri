# frozen_string_literal: true

require_relative "test_helper"

# The instructions of a tool's server go into the conversation as a
# reminder, with the first request when they fit together. What the
# conversation holds decides whether they are owed.
class TestToolInstructions < Minitest::Test
  def tool(name, instructions = nil, **)
    Mistri::Tool.define(name, "Does #{name}.", instructions:, **) { "ran #{name}" }
  end

  def agent(turns, tools:, **)
    provider = Mistri::Providers::Fake.new(turns:)
    [Mistri::Agent.new(provider:, tools:, **), provider]
  end

  def search(query) = { name: "tool_search", arguments: { "query" => query } }

  # Each server's instructions in a request, one text block for each server.
  def instructions(provider, request = -1)
    provider.requests.fetch(request)[:messages]
            .select { |message| message.reminder == "tool_instructions" }
            .flat_map { |message| message.content.map(&:text) }
  end

  def note(tools, text)
    "The server of #{tools} gives these instructions for using its tools:\n#{text}"
  end

  def test_instructions_reach_the_model_with_the_first_request_and_once
    tools = [tool("crm__lookup", "Cite the record id."), tool("plain"), tool("blank", " \n "),
             tool("mirror__lookup", "Cite the record id.\n"),
             tool("tracker__create_issue", "Use project keys.", deferred: true),
             tool("tracker__list_issues", "Use project keys.", deferred: true)]
    agent, provider = agent([{ tool_calls: [search("select:tracker__create_issue")] },
                             { text: "Done." }, { text: "Again." }], tools:)

    agent.run("Go.")
    agent.run("Again.")
    sent = [note("crm__*, mirror__*", "Cite the record id."),
            note("tracker__*", "Use project keys.")]

    assert_equal sent, instructions(provider, 0)
    assert_equal sent, instructions(provider)
  end

  def test_instructions_too_large_to_send_together_follow_the_load_of_a_tool
    tools = %w[a b c d e f g h i j k].map do |server|
      tool("#{server}__read", "#{server} #{"x" * 1_990}", deferred: true)
    end
    agent, provider = agent([{ tool_calls: [search("select:a__read")] },
                             { tool_calls: [search("select:b__read")] }, { text: "Done." }],
                            tools: [tool("crm__lookup", "Cite the record id."), *tools])
    sent = [note("crm__*", "Cite the record id."), note("a__*", "a #{"x" * 1_990}"),
            note("b__*", "b #{"x" * 1_990}")]

    agent.run("Go.")

    assert_equal sent.first(1), instructions(provider, 0)
    assert_equal sent.first(2), instructions(provider, 1)
    assert_equal sent, instructions(provider)
  end

  def test_instructions_that_another_server_s_instructions_contain_are_still_sent
    tools = %w[a b c d e f g h i j k].map do |server|
      tool("#{server}__read", "#{"x" * 1_990}#{" from #{server}" unless server == "b"}",
           deferred: true)
    end
    agent, provider = agent([{ tool_calls: [search("select:a__read")] },
                             { tool_calls: [search("select:b__read")] }, { text: "Done." }], tools:)

    agent.run("Go.")

    assert_equal [note("a__*", "#{"x" * 1_990} from a"), note("b__*", "x" * 1_990)],
                 instructions(provider)
  end

  def test_instructions_longer_than_the_bound_are_cut_with_a_note
    agent, provider = agent([{ text: "Hello." }],
                            tools: [tool("wiki_search", "#{"x" * 1_999}é#{"x" * 500}")])

    agent.run("Hello.")

    assert_equal [note("wiki_search", "#{"x" * 1_999}\n[cut at 2000 of 2501 bytes]")],
                 instructions(provider)
  end

  def test_a_load_that_a_hook_failed_loses_no_instructions
    tools = %w[a b c d e f g h i j k].map do |server|
      tool("#{server}__read", "#{server} #{"x" * 1_990}", deferred: true)
    end
    failing = lambda do |call, _result, _context|
      raise "the hook failed" if call.arguments["query"] == "select:a__read"
    end
    more = tool("a__write", "a #{"x" * 1_990}", deferred: true)
    agent, provider = agent([{ tool_calls: [search("select:a__read"), search("select:a__write")] },
                             { text: "Done." }],
                            tools: [*tools, more], after_tool: failing, max_concurrency: 1)

    agent.run("Go.")

    assert_equal [note("a__*", "a #{"x" * 1_990}")], instructions(provider)
  end

  def test_instructions_are_sent_again_after_a_compaction_summarized_them
    agent, provider = agent([{ text: "One." }, { text: "Two." }, { text: "Summary." },
                             { text: "Three." }],
                            tools: [tool("crm__lookup", "Cite the record id.")],
                            compaction: Mistri::Compaction.new(keep_recent: 1))

    agent.run("First.")
    agent.run("Second.")
    agent.compact
    agent.run("Third.")

    refute_includes provider.requests[2][:messages].last.text, "Cite the record id."
    assert_equal 1, instructions(provider).length
  end
end
