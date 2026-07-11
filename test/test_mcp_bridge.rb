# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_stub_server"

# The bridge: MCP tools become Mistri tools, results become model-readable
# content, and the harness's own features compose on top.
class TestMcpBridge < Minitest::Test
  def remote_client(server)
    Mistri::MCP::Client.new(url: server.url,
                            allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
  end

  def recording_client(listed)
    Class.new do
      def initialize(listed)
        @listed = listed
        @calls = []
      end

      attr_reader :calls

      def tools = @listed

      def call_tool(name, args)
        @calls << [name, args]
        if args["count"].is_a?(Integer) && args["count"] < 1
          return { "isError" => true,
                   "content" => [{ "type" => "text", "text" => "count must be positive" }] }
        end

        { "content" => [{ "type" => "text", "text" => "within bounds" }] }
      end
    end.new(listed)
  end

  def test_tools_map_with_prefix_filters_and_gates
    listed = [{ "name" => "create", "description" => "Creates.",
                "inputSchema" => { "type" => "object",
                                   "properties" => { "title" => { "type" => "string" } } } },
              { "name" => "search", "description" => "Searches." },
              { "name" => "purge", "description" => "Purges." }]
    client = Struct.new(:tools).new(listed)

    tools = Mistri::MCP.tools(client, deny: ["purge"], prefix: "linear",
                                      gates: { "create" => true })

    assert_equal %w[linear__create linear__search], tools.map(&:name)
    assert tools.first.needs_approval?({})
    refute tools.last.needs_approval?({})
    assert_equal({ "type" => "object", "properties" => { "title" => { "type" => "string" } } },
                 tools.first.spec[:input_schema])
  end

  def test_mcp_map_schemas_validate_without_an_adapter
    listed = [{ "name" => "headers", "description" => "Accepts headers.",
                "inputSchema" => {
                  "type" => "object",
                  "additionalProperties" => { "type" => "string" }
                } }]
    tool = Mistri::MCP.tools(Struct.new(:tools).new(listed)).first

    assert_empty tool.argument_violations("authorization" => "redacted")
    assert_equal ["$.attempts must be string, got integer"],
                 tool.argument_violations("attempts" => 2)
  end

  def test_mcp_complete_validator_seam_is_explicit_and_names_bad_tools
    listed = [{ "name" => "labels", "description" => "Accepts labels.",
                "inputSchema" => {
                  "type" => "object",
                  "patternProperties" => { "^x-" => { "type" => "string" } },
                  "additionalProperties" => false
                } }]
    client = Struct.new(:tools).new(listed)

    error = assert_raises(Mistri::ConfigurationError) { Mistri::MCP.tools(client) }

    assert_match(/MCP tool "labels"/, error.message)
    validated = []
    tool = Mistri::MCP.tools(
      client,
      complete_argument_validator: lambda { |arguments, _schema|
        validated << arguments
        []
      }
    ).first

    assert_empty tool.argument_violations("x-team" => "platform")
    assert_equal [{ "x-team" => "platform" }], validated
  end

  def test_mcp_rejects_a_non_object_tool_schema
    client = Struct.new(:tools).new(
      [{ "name" => "disabled", "description" => "Disabled.", "inputSchema" => false }]
    )

    error = assert_raises(Mistri::ConfigurationError) { Mistri::MCP.tools(client) }

    assert_match(/MCP tool "disabled"/, error.message)
    assert_match(/must declare type object/, error.message)
  end

  def test_mcp_distinguishes_an_omitted_schema_from_explicit_null
    omitted = Struct.new(:tools).new([{ "name" => "ping", "description" => "Pings." }])
    null = Struct.new(:tools).new(
      [{ "name" => "broken", "description" => "Broken.", "inputSchema" => nil }]
    )

    tool = Mistri::MCP.tools(omitted).first
    error = assert_raises(Mistri::ConfigurationError) { Mistri::MCP.tools(null) }

    assert_equal({ "type" => "object", "properties" => {},
                   "additionalProperties" => false }, tool.input_schema)
    assert_equal ["$.surprise is not allowed"], tool.argument_violations("surprise" => true)
    assert_match(/MCP tool "broken"/, error.message)
    assert_match(/inputSchema must be an object, not null/, error.message)
  end

  def test_mcp_bridges_unimplemented_assertions_as_server_validated_guidance
    listed = [{ "name" => "bounded", "description" => "Checks a bounded value.",
                "inputSchema" => {
                  "type" => "object",
                  "properties" => { "count" => { "type" => "integer", "minimum" => 1 } },
                  "required" => ["count"]
                } }]
    client = recording_client(listed)

    tool = Mistri::MCP.tools(client).first

    assert_equal ["$.count must be integer, got string"],
                 tool.argument_violations("count" => "one")
    assert_empty tool.argument_violations("count" => 0),
                 "minimum stays guidance for the server, which the MCP spec obligates to validate"
    rejected = tool.call({ "count" => 0 })

    assert_predicate rejected, :error?
    assert_includes rejected.content, "count must be positive"
    assert_equal [["bounded", { "count" => 0 }]], client.calls
  end

  def test_mcp_ignores_inline_vocabulary_declarations_for_instance_validation
    schema = {
      "$vocabulary" => { "https://example.com/vocab" => true },
      "type" => "object"
    }
    client = Struct.new(:tools).new(
      [{ "name" => "custom", "description" => "Custom.", "inputSchema" => schema }]
    )

    tool = Mistri::MCP.tools(client).first

    assert_empty tool.argument_violations({})

    schema["$vocabulary"]["https://example.com/vocab"] = false

    assert Mistri::MCP.tools(client).first
  end

  def test_mcp_pattern_properties_still_require_complete_authority_by_default
    listed = [{ "name" => "labels", "description" => "Labels.",
                "inputSchema" => {
                  "type" => "object",
                  "patternProperties" => { "^x-" => { "type" => "string" } }
                } }]
    client = Struct.new(:tools).new(listed)

    error = assert_raises(Mistri::ConfigurationError) { Mistri::MCP.tools(client) }

    assert_match(/pattern properties require a complete argument validator/, error.message)
  end

  def test_mcp_does_not_promote_format_annotations_into_assertions
    client = Struct.new(:tools).new(
      [{ "name" => "notify", "description" => "Notifies.",
         "inputSchema" => {
           "type" => "object",
           "properties" => { "email" => { "type" => "string", "format" => "email" } }
         } }]
    )

    tool = Mistri::MCP.tools(client).first

    assert_empty tool.argument_violations("email" => "host-policy-validates-if-needed")
  end

  def test_mcp_rejects_malformed_unimplemented_assertions_before_bridging
    client = Struct.new(:tools).new(
      [{ "name" => "broken_dependencies", "description" => "Broken.",
         "inputSchema" => { "type" => "object", "dependentRequired" => [] } }]
    )

    error = assert_raises(Mistri::ConfigurationError) { Mistri::MCP.tools(client) }

    assert_match(/MCP tool "broken_dependencies"/, error.message)
    assert_match(/dependentRequired must be an object/, error.message)
  end

  def test_mcp_allows_only_same_document_references_with_a_complete_validator
    base = {
      "type" => "object",
      "$defs" => { "id" => { "type" => "string" } },
      "properties" => { "id" => { "$ref" => "#/$defs/id" } }
    }
    complete = ->(*) { [] }
    local = Struct.new(:tools).new(
      [{ "name" => "local", "description" => "Local ref.", "inputSchema" => base }]
    )
    external_schema = base.merge(
      "properties" => { "id" => { "$ref" => "https://example.com/id.json" } }
    )
    external = Struct.new(:tools).new(
      [{ "name" => "external", "description" => "External ref.",
         "inputSchema" => external_schema }]
    )

    assert Mistri::MCP.tools(local, complete_argument_validator: complete).first
    assert Mistri::MCP.tools(local).first, "same-document refs bridge as guidance by default"
    %w[$ref $dynamicRef].each do |keyword|
      empty_ref = base.merge("properties" => { "id" => { keyword => "" } })
      empty_client = Struct.new(:tools).new(
        [{ "name" => "empty", "description" => "Empty ref.", "inputSchema" => empty_ref }]
      )

      assert Mistri::MCP.tools(empty_client).first
      assert Mistri::MCP.tools(empty_client,
                               complete_argument_validator: complete).first
    end
    error = assert_raises(Mistri::ConfigurationError) do
      Mistri::MCP.tools(external, complete_argument_validator: complete)
    end

    assert_match(/MCP tool "external"/, error.message)
    assert_match(/same-document reference beginning with #/, error.message)

    default_mode = assert_raises(Mistri::ConfigurationError) { Mistri::MCP.tools(external) }

    assert_match(/same-document reference beginning with #/, default_mode.message)
  end

  def test_answers_map_text_errors_images_and_structured_content
    text = { "content" => [{ "type" => "text", "text" => "found 3" },
                           { "type" => "text", "text" => "more" }] }

    assert_equal "found 3\nmore", Mistri::MCP.answer(text)

    failed = { "isError" => true, "content" => [{ "type" => "text", "text" => "no access" }] }

    error = Mistri::MCP.answer(failed)

    assert_equal "MCP tool error: no access", error.content
    assert_predicate error, :error?

    image = { "content" => [{ "type" => "image", "data" => ["png!"].pack("m0"),
                              "mimeType" => "image/png" }] }
    failed_image = { "isError" => true, "content" => image["content"] }
    image_error = Mistri::MCP.answer(failed_image)

    assert_instance_of Mistri::Content::Image, image_error.content.last
    assert_predicate image_error, :error?

    structured_error = Mistri::MCP.answer(
      "isError" => true, "content" => [],
      "structuredContent" => { "code" => "RATE_LIMITED" }
    )

    assert_includes structured_error.content, '"code":"RATE_LIMITED"'
    assert_predicate structured_error, :error?

    blocks = Mistri::MCP.answer(image)

    assert_instance_of Mistri::Content::Image, blocks.first

    structured = { "content" => [], "structuredContent" => { "count" => 3 } }

    assert_equal '{"count":3}', Mistri::MCP.answer(structured)
  end

  def test_an_agent_uses_a_bridged_tool_end_to_end
    tools = { "lookup" => { description: "Looks up facts.",
                            handler: ->(args) { "fact: #{args["q"]} is 42" } } }
    server = Mistri::Test::McpStubServer.new(tools: tools, session: "s")
    client = remote_client(server)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "kb__lookup",
                                                              arguments: { "q" => "answer" } }] },
                                             { text: "It is 42." }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: Mistri::MCP.tools(client, prefix: "kb"))

    result = agent.run("what is the answer?")

    assert_predicate result, :completed?
    assert_equal "fact: answer is 42", agent.session.messages.select(&:tool?).last.text
    assert_equal "lookup", server.calls.first["name"], "the remote name, not the prefixed one"
  ensure
    server.stop
  end

  def test_mcp_is_error_reaches_the_agent_event_and_session
    tools = { "lookup" => { description: "Looks up facts.", handler: lambda do |_args|
      { "isError" => true,
        "content" => [{ "type" => "text", "text" => "index unavailable" }] }
    end } }
    server = Mistri::Test::McpStubServer.new(tools: tools)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "lookup",
                                                              arguments: {} }] },
                                             { text: "I will use another source." }
                                           ])
    events = []
    agent = Mistri::Agent.new(provider:, tools: Mistri::MCP.tools(remote_client(server)))

    agent.run("look it up") { |event| events << event }

    event = events.find { |item| item.type == :tool_result }

    assert_predicate event, :tool_error?
    assert_predicate agent.session.messages.find(&:tool?), :tool_error?
  ensure
    server&.stop
  end

  def test_an_ambiguous_delivery_warns_the_model_not_to_retry
    tools = { "send" => { description: "Sends once.", handler: ->(_) { "sent" } } }
    server = Mistri::Test::McpStubServer.new(tools: tools, drop_after: "tools/call")
    client = remote_client(server)
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send", arguments: {} }] },
                                             { text: "I will verify before retrying." }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: Mistri::MCP.tools(client))

    agent.run("send it")

    result = agent.session.messages.find(&:tool?)

    assert_match(/AmbiguousDeliveryError/, result.text)
    assert_match(/do not retry automatically/, result.text)
    assert_predicate result, :tool_error?
    assert_equal 1, server.calls.length
  ensure
    server&.stop
  end

  def test_an_approval_gate_parks_a_bridged_tool_before_the_server_sees_it
    tools = { "send" => { description: "Sends.", handler: ->(_) { "sent" } } }
    server = Mistri::Test::McpStubServer.new(tools: tools)
    client = remote_client(server)
    bridged = Mistri::MCP.tools(client, gates: { "send" => true })
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send", arguments: {} }] }
                                           ])

    result = Mistri::Agent.new(provider:, tools: bridged).run("send it")

    assert_predicate result, :awaiting_approval?
    assert_empty server.calls, "the third-party tool never ran without a human"
  ensure
    server.stop
  end
end
