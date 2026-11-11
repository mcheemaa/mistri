# frozen_string_literal: true

require "securerandom"
require_relative "test_helper"

# Deferred tools against the real Responses API with store false. Every model
# that loads tools must call one an additional_tools item declared, take the
# replay of that call, and keep its cached prefix across the load.
class TestOpenAIDeferredToolsLive < Minitest::Test
  MODELS = Mistri::Models::CATALOG.each_value.select do |model|
    model.provider == :openai && Mistri::Models.tool_loading?(model.id)
  end
  RULES = Array.new(320) do |index|
    "Rule #{index + 1}: keep a project key in upper case and never invent one."
  end.join("\n")
  ASK = "Open an issue titled 'Login is slow'. Find the tool first."

  def setup
    skip "set MISTRI_LIVE=1 for live tests" unless ENV["MISTRI_LIVE"] == "1"
    skip "no OPENAI_API_KEY" if ENV["OPENAI_API_KEY"].to_s.empty?
  end

  def teardown
    @provider&.close
  end

  def provider(model)
    @provider = Mistri::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"), model:,
                                              read_timeout: 120)
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

  def searched
    search = Mistri::ToolCall.new(id: "call_search", name: "tool_search",
                                  arguments: { "query" => "create issue" })
    [Mistri::Message.user(ASK),
     Mistri::Message.assistant(tool_calls: [search], stop_reason: :tool_use),
     Mistri::Message.tool(content: "Loaded 1 tool.", tool_call_id: "call_search",
                          tool_name: "tool_search", loads: ["tracker__create_issue"])]
  end

  def stream(model, history, tools)
    Mistri::Test.retry_transient do
      provider(model).stream(messages: history, tools: [Mistri::ToolSearch.tool(tools).spec],
                             deferred_tools: tools.map(&:spec))
    end
  end

  def created(call)
    Mistri::Message.tool(content: "Created WEB-101.", tool_call_id: call.id, tool_name: call.name)
  end

  MODELS.each do |model|
    name = "test_#{model.id.gsub(/[.-]/, "_")}_calls_a_declared_tool_and_takes_the_replay"
    define_method(name) do
      tools = tracker_tools
      message = stream(model.id, searched, tools)

      assert_equal :tool_use, message.stop_reason,
                   "#{model.id} did not call a tool: #{message.error_message || message.text}"
      assert_equal %w[tracker__create_issue], message.tool_calls.map(&:name)

      answer = stream(model.id, [*searched, message, created(message.tool_calls.first)], tools)

      assert_equal :stop, answer.stop_reason,
                   "#{model.id} refused the replay: #{answer.error_message}"
    end
  end

  def test_a_call_made_by_another_provider_is_replayed_to_a_model_that_wants_the_namespace
    tools = tracker_tools
    foreign = Mistri::ToolCall.new(id: "call_create", name: "tracker__create_issue",
                                   arguments: { "title" => "Login is slow" })
    history = [*searched, Mistri::Message.assistant(tool_calls: [foreign], stop_reason: :tool_use),
               created(foreign)]

    answer = stream("gpt-5.5", history, tools)

    assert_equal :stop, answer.stop_reason, "the replay was refused: #{answer.error_message}"
  end

  def test_a_load_leaves_the_cached_prefix_in_place_and_a_later_run_reads_it
    made = []
    session = Mistri::Session.new(store: Mistri::Stores::Memory.new)
    system = "Run #{SecureRandom.hex(8)}. You work in a tracker. Be brief.\n#{RULES}"
    agent = Mistri::Agent.new(provider: provider("gpt-6.1-terra"), session:,
                              tools: tracker_tools(made), system:)

    result = agent.run("Open an issue titled 'Login is slow'.")
    turns = session.messages.select(&:assistant?)

    assert_predicate result, :completed?
    assert_equal ["Login is slow"], made
    assert_equal "tool_search", turns.first.tool_calls.first.name
    assert_operator turns[1].usage.cache_read, :>, 1_000,
                    "the request after the load did not read the cached prefix"

    later = Mistri::Agent.new(provider: @provider, session:, tools: tracker_tools(made), system:)
    result = later.run("Now open another one titled 'Logout is missing'.")
    again = session.messages.select(&:assistant?)[turns.length]

    assert_predicate result, :completed?
    assert_equal ["Login is slow", "Logout is missing"], made
    assert_equal %w[tracker__create_issue], again.tool_calls.map(&:name),
                 "the later run searched again or did not call the loaded tool"
    assert_operator again.usage.cache_read, :>, 1_000
  end
end
