# frozen_string_literal: true

require_relative "test_helper"

# Tool argument validation is the trust boundary before host policy and side
# effects. Invalid calls answer the model in band while valid siblings proceed.
class TestToolArgumentValidation < Minitest::Test
  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def test_invalid_arguments_cannot_bypass_approval_or_reach_any_execution_hook
    touched = []
    approval = lambda do |args|
      touched << :approval
      args["total_usd"].to_i > 500
    end
    schema = -> { number :total_usd, "Order total", required: true }
    tool = Mistri::Tool.define(
      "purchase", "Purchase an order.", ends_turn: true,
                                        needs_approval: approval, schema:
    ) do
      touched << :handler
      "purchased"
    end
    provider = fake(
      { tool_calls: [{ name: "purchase", arguments: { "total_usd" => "all" } }] },
      { text: "I need to correct the amount." }
    )
    events = []
    agent = Mistri::Agent.new(
      provider:, tools: [tool],
      before_tool: ->(*) { touched << :before },
      after_tool: ->(*) { touched << :after }
    )

    result = agent.run("buy everything") { |event| events << event }

    assert_predicate result, :completed?
    refute_predicate result, :handed_off?
    assert_empty touched
    assert_empty agent.session.open_approvals
    refute(events.any? { |event| event.type == :tool_started })
    answer = agent.session.messages.find(&:tool?)

    assert_predicate answer, :tool_error?
    assert_includes answer.text, "must be number"
  end

  def test_a_schema_less_tool_rejects_undeclared_model_arguments
    touched = []
    tool = Mistri::Tool.define("ping", "Takes no arguments.", needs_approval: lambda { |*|
      touched << :approval
      false
    }) do
      touched << :handler
      "pong"
    end
    provider = fake(
      { tool_calls: [{ name: "ping", arguments: { "surprise" => 1 } }] },
      { text: "corrected" }
    )
    agent = Mistri::Agent.new(provider:, tools: [tool])

    result = agent.run("ping")

    assert_predicate result, :completed?
    assert_empty touched
    answer = agent.session.messages.find(&:tool?)

    assert_predicate answer, :tool_error?
    assert_includes answer.text, "$.surprise is not allowed"
  end

  def test_programmatic_numeric_overflow_never_reaches_policy_or_the_handler
    arguments = Mistri.const_get(:ToolArguments, false)
    huge_integer = 1 << ((arguments::MAX_NUMBER_BYTES + 1) * 4)
    touched = []
    tool = Mistri::Tool.define(
      "purchase", "Purchases.", needs_approval: ->(*) { touched << :policy },
                                schema: -> { integer :amount, "Amount", required: true }
    ) { touched << :handler }
    provider = fake(
      { tool_calls: [{ name: "purchase", arguments: { "amount" => huge_integer } }] },
      { text: "arguments were rejected" }
    )

    agent = Mistri::Agent.new(provider:, tools: [tool])
    result = agent.run("buy")

    assert_predicate result, :completed?
    assert_empty touched
    answer = agent.session.messages.find(&:tool?)

    assert_predicate answer, :tool_error?
    assert_includes answer.text, "arguments were not valid bounded JSON"
  end

  def test_normalization_runs_once_before_approval_and_owns_its_result
    normalized = 0
    observations = []
    normalizer = lambda do |args|
      normalized += 1
      observations << [args.frozen?, args["meta"].frozen?]
      { "recipient" => args.fetch("to"), "meta" => args.fetch("meta") }
    end
    schema = lambda do
      string :recipient, "Recipient", required: true
      object :meta, "Metadata", required: true do
        string :source, "Source", required: true
      end
    end
    tool = Mistri::Tool.define(
      "send", "Send a message.", needs_approval: true,
                                 argument_normalizer: normalizer, schema:
    ) do |args|
      observations << [args.frozen?, args["meta"].frozen?]
      "sent to #{args.fetch("recipient")}"
    end
    provider = fake(
      { tool_calls: [{ name: "send",
                       arguments: { "to" => "Ana", "meta" => { "source" => "model" } } }] },
      { text: "done" }
    )
    agent = Mistri::Agent.new(provider:, tools: [tool])

    pending = agent.run("send it").pending.first

    assert_equal({ "recipient" => "Ana", "meta" => { "source" => "model" } },
                 pending.arguments)
    agent.session.approve(pending.id)
    agent.resume

    assert_equal 1, normalized
    assert_equal [[true, true], [true, true]], observations
  end

  def test_resumed_approvals_use_current_tools_and_schemas_without_renormalizing
    store = Mistri::Stores::Memory.new
    session = Mistri::Session.new(store:)
    normalizations = 0
    normalizer = lambda do |args|
      normalizations += 1
      args
    end
    old_tools = [
      Mistri::Tool.define(
        "changed", "Changed later.", needs_approval: true,
                                     argument_normalizer: normalizer,
                                     schema: -> { string :amount, "Amount", required: true }
      ) { "old" },
      Mistri::Tool.define("removed", "Removed later.", needs_approval: true) { "old" }
    ]
    first = Mistri::Agent.new(
      provider: fake({ tool_calls: [
                       { id: "changed-1", name: "changed",
                         arguments: { "amount" => "ten" } },
                       { id: "removed-1", name: "removed", arguments: {} }
                     ] }),
      tools: old_tools, session:
    )
    pending = first.run("go").pending

    assert_equal %w[changed-1 removed-1], pending.map(&:id)
    pending.each { |call| session.approve(call.id) }

    reject_normalization = ->(*) { flunk "a parked call was normalized twice" }
    replacement = Mistri::Tool.define(
      "changed", "Now requires a number.", needs_approval: true,
                                           argument_normalizer: reject_normalization,
                                           schema: -> { number :amount, "Amount", required: true }
    ) { flunk "an invalid approved call executed" }
    resumed = Mistri::Agent.new(
      provider: fake({ text: "Please submit corrected calls." }), tools: [replacement],
      session: Mistri::Session.new(store:, id: session.id)
    )

    result = resumed.resume

    assert_predicate result, :completed?
    assert_equal 1, normalizations
    answers = resumed.session.messages.select(&:tool?)

    assert_equal %w[changed removed], answers.map(&:tool_name)
    assert answers.all?(&:tool_error?)
    assert_includes answers.first.text, "must be number"
    assert_includes answers.last.text, "Unknown tool"
  end

  def test_mixed_valid_and_invalid_calls_keep_model_order
    ran = []
    schema = -> { integer :count, "Count", required: true }
    copy_arguments = lambda(&:merge)
    tools = %w[first middle last].map do |name|
      Mistri::Tool.define(name, "Runs.", argument_normalizer: copy_arguments, schema:) do
        ran << name
        name
      end
    end
    provider = fake(
      { tool_calls: [
        { id: "first-1", name: "first", arguments: { "count" => 1 } },
        { id: "middle-1", name: "middle", arguments: { "count" => "many" } },
        { id: "last-1", name: "last", arguments: { "count" => 3 } }
      ] },
      { text: "done" }
    )
    agent = Mistri::Agent.new(provider:, tools:, max_concurrency: 1)

    agent.run("go")

    assert_equal %w[first last], ran
    answers = agent.session.messages.select(&:tool?)

    assert_equal %w[first middle last], answers.map(&:tool_name)
    assert_equal ["first", true, "last"],
                 [answers[0].text, answers[1].tool_error?, answers[2].text]
  end

  def test_custom_validator_supplements_core_and_errors_are_bounded
    values = Array.new(20) { |index| "host rule #{index}" }
    values[0] = "host rule 0: #{"x" * 2_000_000}"
    tool = Mistri::Tool.define(
      "custom", "Custom rules.", argument_validator: ->(_args, _schema) { values }
    ) { flunk "custom-invalid arguments executed" }
    provider = fake({ tool_calls: [{ name: "custom", arguments: {} }] },
                    { text: "correcting" })
    agent = Mistri::Agent.new(provider:, tools: [tool])

    agent.run("go")

    answer = agent.session.messages.find(&:tool?)

    assert_predicate answer, :tool_error?
    assert_operator answer.text.bytesize, :<=, 2048
    assert_includes answer.text, "host rule 0"
    refute_includes answer.text, "host rule 8"
  end

  def test_core_failure_skips_the_host_validator
    validations = 0
    tool = Mistri::Tool.define(
      "typed", "Typed.",
      argument_validator: lambda { |*|
        validations += 1
        []
      },
      schema: -> { integer :count, "Count", required: true }
    ) { flunk "invalid arguments executed" }
    provider = fake({ tool_calls: [{ name: "typed", arguments: { "count" => "one" } }] },
                    { text: "correcting" })

    Mistri::Agent.new(provider:, tools: [tool]).run("go")

    assert_equal 0, validations
  end
end

# Normalizer, host-validator, and remote-boundary failures all fail closed.
class TestToolArgumentBoundaryFailures < Minitest::Test
  def fake(*turns) = Mistri::Providers::Fake.new(turns: turns)

  def test_invalid_normalizer_results_fail_before_policy
    touched = []
    cyclic = Mistri::Tool.define(
      "cyclic", "Cyclic.",
      argument_normalizer: lambda { |_args|
        value = {}
        value["self"] = value
        value
      }
    ) { touched << :handler }
    scalar = Mistri::Tool.define("scalar", "Scalar.",
                                 argument_normalizer: ->(_args) { "not an object" }) do
      touched << :handler
    end
    raises = Mistri::Tool.define("raises", "Raises.",
                                 argument_normalizer: ->(*) { raise "normalizer secret" }) do
      touched << :handler
    end
    provider = fake(
      { tool_calls: [{ name: "cyclic", arguments: {} },
                     { name: "scalar", arguments: {} },
                     { name: "raises", arguments: {} }] },
      { text: "host configuration needs attention" }
    )
    agent = Mistri::Agent.new(
      provider:, tools: [cyclic, scalar, raises],
      before_tool: ->(*) { touched << :before }
    )

    agent.run("go")

    assert_empty touched
    answers = agent.session.messages.select(&:tool?)

    assert_equal %w[cyclic scalar raises], answers.map(&:tool_name)
    assert answers.all?(&:tool_error?)
    assert(answers.all? { |answer| answer.text.include?("argument normalizer") })
    assert_includes answers[0].text, "TypeError"
    assert_includes answers[1].text, "ArgumentError"
    assert_includes answers[2].text, "RuntimeError"
    refute_includes answers[2].text, "normalizer secret"
  end

  def test_host_validator_failures_are_closed_without_leaking_details
    tools = [
      Mistri::Tool.define("raises", "Raises.",
                          argument_validator: ->(*) { raise "database password" }) do
        flunk "validator failure executed"
      end,
      Mistri::Tool.define("bad_return", "Bad return.", argument_validator: ->(*) { "no" }) do
        flunk "invalid validator return executed"
      end
    ]
    provider = fake(
      { tool_calls: [{ name: "raises", arguments: {} },
                     { name: "bad_return", arguments: {} }] },
      { text: "correcting" }
    )
    agent = Mistri::Agent.new(provider:, tools:)

    agent.run("go")

    answers = agent.session.messages.select(&:tool?)

    assert answers.all?(&:tool_error?)
    assert(answers.all? { |answer| answer.text.include?("argument validator") })
    assert_includes answers[0].text, "RuntimeError"
    assert_includes answers[1].text, "TypeError"
    refute(answers.any? { |answer| answer.text.include?("database password") })
  end

  def test_edit_file_alias_collisions_never_reach_the_workspace
    workspace = Mistri::Workspace::Memory.new
    workspace.write("a.txt", "old")
    workspace.write("b.txt", "old")
    provider = fake(
      { tool_calls: [{ name: "edit_file",
                       arguments: { "file" => "a.txt", "path" => "b.txt",
                                    "oldText" => "old", "newText" => "new" } }] },
      { text: "I will choose one path." }
    )
    agent = Mistri::Agent.new(provider:, tools: [Mistri::Tools.edit_file(workspace)])

    agent.run("edit it")

    assert_equal "old", workspace.read("a.txt")
    assert_equal "old", workspace.read("b.txt")
    assert_predicate agent.session.messages.find(&:tool?), :tool_error?
  end

  def test_direct_tool_calls_are_trusted_but_still_apply_the_tool_normalizer
    validations = 0
    normalizations = 0
    seen = nil
    tool = Mistri::Tool.define(
      "direct", "Direct.",
      argument_normalizer: lambda { |args|
        normalizations += 1
        seen = args
        { "name" => args.fetch("legacy_name") }
      },
      argument_validator: lambda { |*|
        validations += 1
        ["rejected"]
      }
    ) { |args| args.fetch("name") }

    input = { "legacy_name" => "Ana" }

    assert_equal "Ana", tool.call(input)
    assert_same input, seen
    refute_predicate seen, :frozen?
    assert_equal 1, normalizations
    assert_equal 0, validations
  end

  def test_non_object_and_malformed_arguments_fail_before_policy
    touched = []
    tool = Mistri::Tool.define("run", "Runs.", needs_approval: lambda { |_args|
      touched << :approval
    }) { touched << :handler }
    provider = fake(
      { tool_calls: [{ name: "run", arguments: [1, 2] },
                     { name: "run", arguments: {}, arguments_error: "invalid_json" },
                     { name: "run", arguments: {}, arguments_error: "too_large" }] },
      { text: "correcting" }
    )
    agent = Mistri::Agent.new(provider:, tools: [tool],
                              before_tool: ->(*) { touched << :before })

    agent.run("go")

    assert_empty touched
    answers = agent.session.messages.select(&:tool?)

    assert_equal 3, answers.length
    assert answers.all?(&:tool_error?)
    assert_includes answers.first.text, "JSON object"
    assert_includes answers[1].text, "not valid JSON"
    assert_includes answers.last.text, "bounded JSON"
  end

  def test_completed_arguments_have_an_aggregate_byte_ceiling
    call = Mistri::ToolCall.new(
      id: "large-1", name: "run", arguments: { "value" => "x" * (8 * 1024 * 1024) }
    )

    assert_nil call.arguments
    assert_equal "too_large", call.arguments_error
  end

  def test_a_custom_provider_partial_is_reowned_before_policy
    retained = { "nested" => { "count" => 1 } }
    call = Mistri::ToolCall.new(id: "c1", name: "run", arguments: retained,
                                canonicalize: false)
    provider = Class.new do
      define_method(:model) { "custom-1" }
      define_method(:prices_usage?) { true }
      define_method(:stream) do |**|
        Mistri::Message.assistant(tool_calls: [call], stop_reason: Mistri::StopReason::TOOL_USE,
                                  usage: Mistri::Usage.zero)
      end
    end.new
    observed = nil
    tool = Mistri::Tool.define("run", "Runs.", ends_turn: true, schema: lambda {
      object :nested, required: true do
        integer :count, required: true
      end
    }) do |args|
      observed = args.dig("nested", "count")
      "done"
    end
    agent = Mistri::Agent.new(provider:, tools: [tool], before_tool: lambda { |_call, _context|
      retained["nested"]["count"] = "changed after validation"
      nil
    })

    agent.run("go")

    assert_equal 1, observed
  end

  def test_invalid_mcp_arguments_never_reach_the_remote_handler
    client = Class.new do
      attr_reader :tools, :calls

      def initialize
        @calls = []
        @tools = [{ "name" => "charge", "description" => "Charges.",
                    "inputSchema" => {
                      "type" => "object",
                      "properties" => { "amount" => { "type" => "number" } },
                      "required" => ["amount"]
                    } }]
      end

      def call_tool(name, arguments)
        @calls << [name, arguments]
        { "content" => [{ "type" => "text", "text" => "charged" }] }
      end
    end.new
    provider = fake({ tool_calls: [{ name: "charge", arguments: { "amount" => "all" } }] },
                    { text: "correcting" })
    agent = Mistri::Agent.new(provider:, tools: Mistri::MCP.tools(client))

    agent.run("charge it")

    assert_empty client.calls
    assert_predicate agent.session.messages.find(&:tool?), :tool_error?
  end
end
