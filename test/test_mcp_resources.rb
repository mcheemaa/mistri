# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mcp_scripted_server"

# What a server's resources become for a model: a tool that reads one, a
# link that names that tool, and embedded bytes shown, read or kept.
class TestMcpResources < Minitest::Test
  HAS = { "resources" => {} }.freeze
  # The class an agent wraps its scratchpad workspace in.
  SCRATCHPAD = Mistri.const_get(:Scratchpad)
  PDF = "%PDF-1.7 \xFF\x00 bytes".b.freeze
  NOTES = [{ "uri" => "notes://today", "mimeType" => "text/plain", "text" => "Buy plums." }].freeze
  RESOURCES = {
    "notes://today" => NOTES,
    "notes://folder" => [NOTES.first, { "uri" => "notes://report.pdf", "blob" => [PDF].pack("m0"),
                                        "mimeType" => "application/pdf" }],
    "notes://broken" => { "content" => "not the shape" },
    "notes://words" => "not an object",
    "notes://untyped" => [{ "uri" => "notes://untyped", "blob" => [PDF].pack("m0") }]
  }.freeze
  LINKED = [{ "type" => "text", "text" => "Two things:" },
            { "type" => "resource_link", "uri" => "notes://today", "name" => "today",
              "title" => "Today's notes", "mimeType" => "text/plain", "size" => 10,
              "description" => "What to buy." },
            { "type" => "resource_link", "uri" => "notes://bare" }].freeze
  TOOLS = {
    "links" => ->(server, socket, id) { server.result(socket, id, { "content" => LINKED }) },
    "report" => lambda do |server, socket, id|
      report = { "type" => "resource", "resource" => RESOURCES["notes://folder"].last }
      server.result(socket, id, { "content" => [report] })
    end
  }.freeze
  LISTED = TOOLS.keys.map { |name| { "name" => name } }.freeze

  # A workspace that holds only text, as one in a text column does.
  class TextOnly < Mistri::Workspace::Memory
    def write(path, content)
      unless content.dup.force_encoding("UTF-8").valid_encoding?
        raise ArgumentError,
              "this workspace holds only text"
      end

      super
    end
    alias compare_and_write_bytes write

    def compare_and_write(path, content, **)
      write(path, content)
    end
  end

  def teardown
    @client&.close
    @server&.stop
  end

  def test_a_client_knows_whether_its_server_has_resources
    assert_predicate client, :resources?

    teardown

    refute_predicate client(capabilities: {}), :resources?

    teardown
    newest = { "supportedVersions" => ["2026-07-28"], "capabilities" => HAS }

    assert_predicate client(capabilities: {}, discover: newest), :resources?
  end

  def test_a_stored_listing_says_so_and_a_client_built_from_it_asks_nothing
    kept = client.listing

    assert kept["resources"]

    teardown
    rebuilt = client(listing: JSON.parse(JSON.generate(kept)))

    assert_predicate rebuilt, :resources?
    assert_empty @server.posted

    teardown

    refute client(capabilities: {}).listing.key?("resources")
  end

  def test_reading_a_resource_returns_its_contents
    assert_equal NOTES, client.read_resource("notes://today")

    error = assert_raises(Mistri::MCP::Error) { @client.read_resource("notes://nothing") }

    assert_equal [-32_602, "Resource not found"], [error.code, error.message]
    %w[notes://broken notes://words].each do |uri|
      error = assert_raises(Mistri::MCP::Error) { @client.read_resource(uri) }

      assert_match(/malformed result/, error.message)
    end
  end

  def test_a_server_with_resources_gets_a_tool_that_reads_them
    reader = Mistri::MCP.tools(client, prefix: "notes").last

    assert_equal "notes__read_resource", reader.name
    assert_predicate reader, :parallel?
    assert_equal ["uri"], reader.input_schema["required"]
    assert_equal "Buy plums.", reader.call({ "uri" => "notes://today" })
  end

  def test_the_host_can_offer_the_tool_or_leave_it_out
    names = ->(**options) { Mistri::MCP.tools(@client, **options).map(&:name) }
    client

    assert_equal %w[links report read_resource], names.call
    assert_equal %w[links report], names.call(resources: false)

    teardown
    client(capabilities: {})

    assert_equal %w[links report], names.call
    assert_equal %w[links report read_resource], names.call(resources: true)
  end

  def test_a_servers_own_tool_of_that_name_keeps_it
    client(listed: [*LISTED, { "name" => "read_resource", "description" => "The server's own." }])
    tools = Mistri::MCP.tools(@client)

    assert_equal %w[links report read_resource], tools.map(&:name)
    assert_equal "The server's own.", tools.last.description
  end

  def test_the_tool_follows_the_gate_and_the_deferral_of_the_servers_tools
    reader = Mistri::MCP.tools(client, gates: { "read_resource" => true }, deferred: true).last

    assert reader.needs_approval?({})
    assert_predicate reader, :deferred?
    refute Mistri::MCP.tools(@client).last.needs_approval?({})
  end

  def test_several_contents_are_named_and_a_failed_read_says_which_server
    reader = Mistri::MCP.tools(client, prefix: "notes").last
    several = reader.call({ "uri" => "notes://folder" })

    assert_match(%r{\Anotes://today:\nBuy plums\.\nnotes://report\.pdf:\n\[Binary resource },
                 several)

    failed = reader.call({ "uri" => "notes://nothing" })

    assert failed.error
    assert_equal 'notes__read_resource could not read the resource from the MCP server "notes": ' \
                 "Resource not found", failed.content
  end

  def test_a_link_from_a_bridged_tool_names_the_tool_that_reads_it
    links = Mistri::MCP.tools(client, prefix: "notes").first

    assert_equal "Two things:\n" \
                 '[Resource notes://today "Today\'s notes" (text/plain, 10 bytes). What to buy. ' \
                 "Read it with notes__read_resource.]\n" \
                 "[Resource notes://bare. Read it with notes__read_resource.]",
                 links.call({})
    assert_equal "Two things:\n[resource: notes://today]\n[resource: notes://bare]",
                 Mistri::MCP.tools(@client, resources: false).first.call({})
  end

  def test_embedded_bytes_that_are_no_image_and_no_text_are_kept_in_the_scratchpad
    workspace = Mistri::Workspace::Memory.new
    context = Mistri::ToolContext.new(scratchpad: SCRATCHPAD.new(workspace))
    said = Mistri::MCP.tools(client, prefix: "notes")[1].call({}, context)
    path = said[/saved at (\S+)\]/, 1]

    saved = %r{saved at scratchpad/tool-results/\d+T\d+-notes__report-\h{8}\.pdf\]\z}

    assert said.start_with?("[Binary resource notes://report.pdf (application/pdf, " \
                            "#{PDF.bytesize} bytes) saved at ")
    assert_match(saved, said)
    assert_equal PDF, workspace.read(path).b
  end

  def test_bytes_with_nowhere_to_go_are_named_and_the_reason_given
    report = Mistri::MCP.tools(client, prefix: "notes")[1]

    about = "[Binary resource notes://report.pdf (application/pdf, #{PDF.bytesize} bytes)"

    assert_equal "#{about} is not shown: the agent has no scratchpad to keep it in]",
                 report.call({})
    untyped = Mistri::MCP.tools(@client).last.call({ "uri" => "notes://untyped" })

    assert untyped.start_with?("[Binary resource notes://untyped (unknown type, ")

    text_only = Mistri::ToolContext.new(scratchpad: SCRATCHPAD.new(TextOnly.new))

    assert_equal "#{about} could not be saved: this workspace holds only text]",
                 report.call({}, text_only)
  end

  def test_an_answer_shows_an_image_reads_text_and_names_the_rest
    embedded = lambda do |resource|
      Mistri::MCP.answer({ "content" => [{ "type" => "resource", "resource" => resource }] })
    end
    image = embedded.call("uri" => "a://b.png", "mimeType" => "image/png",
                          "blob" => ["png!"].pack("m0")).first

    assert_equal ["image/png", "png!"], [image.mime_type, image.bytes]
    assert_equal '{"a":1}', embedded.call("uri" => "a://b", "mimeType" => "application/json",
                                          "blob" => ['{"a":1}'].pack("m0"))
    assert_equal "<svg/>", embedded.call("uri" => "a://b", "mimeType" => "image+odd/svg+xml",
                                         "blob" => ["<svg/>"].pack("m0"))
    assert_equal "[resource: a://b]", embedded.call("uri" => "a://b", "mimeType" => "text/plain",
                                                    "blob" => ["\xFF\xFE".b].pack("m0"))
    assert_equal "[resource: a://b]", embedded.call("uri" => "a://b", "blob" => [PDF].pack("m0"))
    assert_equal "[resource: a://b]", embedded.call("uri" => "a://b")
    assert_equal "kept", embedded.call("uri" => "a://b", "text" => "kept")
  end

  def test_an_agent_with_a_scratchpad_keeps_a_binary_a_tool_returned
    workspace = Mistri::Workspace::Memory.new
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: [{ name: "notes__report",
                                                                    arguments: {} }] },
                                                   { text: "Saved." }])
    agent = Mistri::Agent.new(provider:, scratchpad: workspace,
                              tools: Mistri::MCP.tools(client, prefix: "notes"))
    agent.run("Get the report.")
    said = agent.session.messages.find(&:tool?).text

    assert_match(%r{saved at scratchpad/tool-results/}, said)
    assert_equal PDF, workspace.read(said[/saved at (\S+)\]/, 1]).b
  end

  def test_the_scratchpad_names_a_binary_by_its_tool_and_extension
    workspace = Mistri::Workspace::Memory.new
    scratchpad = SCRATCHPAD.new(workspace)

    assert_match(%r{\Ascratchpad/tool-results/\d+T\d+-a_tool-\h{8}\.bin\z},
                 scratchpad.save_binary(PDF, "a tool"))
    assert_match(/\.zip\z/, scratchpad.save_binary(PDF, "a tool", ".zip"))
  end

  private

  def client(capabilities: HAS, listing: nil, listed: LISTED, **)
    @server = Mistri::Test::McpScriptedServer.new(tools: TOOLS, listed: listed,
                                                  resources: RESOURCES,
                                                  capabilities: capabilities, **)
    @client = Mistri::MCP::Client.new(url: @server.url, read_timeout: 10, listing: listing,
                                      allow_non_public: Mistri::Test::ALLOW_LOOPBACK)
  end
end
