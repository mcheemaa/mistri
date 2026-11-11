# frozen_string_literal: true

require "securerandom"
require_relative "test_helper"

# Deferred tools against the real Messages API. Every catalogued model must
# take the reserved definition, a loaded one and a result that references it,
# and a load must leave the cached prefix in place.
class TestAnthropicDeferredToolsLive < Minitest::Test
  MODELS = Mistri::Models::CATALOG.each_value.select { |model| model.provider == :anthropic }
  RULES = Array.new(320) do |index|
    "Rule #{index + 1}: keep a project key in upper case and never invent one."
  end.join("\n")

  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no ANTHROPIC_API_KEY" if ENV["ANTHROPIC_API_KEY"].to_s.empty?
  end

  def teardown
    @provider&.close
  end

  def provider(model)
    @provider = Mistri::Providers::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"),
                                                 model:, read_timeout: 120)
  end

  def tracker_tools(created = [])
    title = -> { string :title, "The issue's title", required: true }
    create = Mistri::Tool.define("tracker__create_issue", "Opens an issue in the tracker.",
                                 deferred: true, schema: title) do |args|
      created << args["title"]
      "Created WEB-#{100 + created.length}."
    end
    others = %w[update_issue delete_issue list_issues list_projects add_comment list_teams]
             .map do |name|
      Mistri::Tool.define("tracker__#{name}", "#{name.tr("_", " ").capitalize} in the tracker.",
                          deferred: true) { "ran #{name}" }
    end
    [create, *others]
  end

  MODELS.each do |model|
    define_method("test_#{model.id.tr("-", "_")}_calls_a_tool_a_result_referenced") do
      tools = tracker_tools
      search = Mistri::ToolCall.new(id: "call_search", name: "tool_search",
                                    arguments: { "query" => "create issue" })
      history = [
        Mistri::Message.user("Open an issue titled 'Login is slow'. Find the tool first."),
        Mistri::Message.assistant(tool_calls: [search], stop_reason: :tool_use),
        Mistri::Message.tool(content: "Loaded 1 tool.", tool_call_id: "call_search",
                             tool_name: "tool_search", loads: ["tracker__create_issue"])
      ]

      message = Mistri::Test.retry_transient do
        provider(model.id).stream(messages: history,
                                  tools: [Mistri::ToolSearch.tool(tools).spec],
                                  deferred_tools: [tools.first.spec])
      end

      assert_equal :tool_use, message.stop_reason,
                   "#{model.id} did not call a tool: #{message.error_message || message.text}"
      assert_equal %w[tracker__create_issue], message.tool_calls.map(&:name)
    end
  end

  def test_a_load_leaves_the_cached_prefix_in_place_and_a_later_run_reads_it
    created = []
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    system = "Run #{SecureRandom.hex(8)}. You work in a tracker. Be brief.\n#{RULES}"
    agent = Mistri::Agent.new(provider: provider("claude-haiku-5-5"), session:,
                              tools: tracker_tools(created), system:)

    result = agent.run("Open an issue titled 'Login is slow'.")
    turns = session.messages.select(&:assistant?)

    assert_predicate result, :completed?
    assert_equal ["Login is slow"], created
    assert_equal "tool_search", turns.first.tool_calls.first.name
    assert_operator turns.first.usage.cache_write, :>, 0, "the prefix was not long enough to cache"
    assert_operator turns[1].usage.cache_read, :>=, turns.first.usage.cache_write,
                    "the request after the load did not read the cached prefix"

    later = Mistri::Agent.new(provider: @provider, session:, tools: tracker_tools(created),
                              system:)
    result = later.run("Now open another one titled 'Logout is missing'.")
    again = session.messages.select(&:assistant?)[turns.length]

    assert_predicate result, :completed?
    assert_equal ["Login is slow", "Logout is missing"], created
    assert_equal %w[tracker__create_issue], again.tool_calls.map(&:name),
                 "the later run searched again or did not call the loaded tool"
    assert_operator again.usage.cache_read, :>, turns.first.usage.cache_write
  end
end
