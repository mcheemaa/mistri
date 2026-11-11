# frozen_string_literal: true

require_relative "test_helper"

# A bridged tool gets a name every provider takes, made from the remote name
# alone. The remote name is still the one the server is called with.
class TestMcpToolNames < Minitest::Test
  SAFE = /\A[A-Za-z_][A-Za-z0-9_-]{0,63}\z/

  def client_for(*names)
    listed = names.map { |name| { "name" => name, "description" => "Does #{name}." } }
    Class.new do
      attr_reader :calls

      def initialize(listed)
        @listed = listed
        @calls = []
      end

      def tools = @listed

      def call_tool(name, arguments)
        @calls << name
        { "content" => [{ "type" => "text", "text" => "ran #{name} #{arguments}" }] }
      end
    end.new(listed)
  end

  def test_a_name_a_provider_would_refuse_is_made_safe_and_still_calls_the_remote_tool
    long = "export_#{"x" * 140}"
    client = client_for("issues.list/open", long, "9lives")

    tools = Mistri::MCP.tools(client, prefix: "tracker")
    tools.each { |tool| tool.call({}, nil) }

    assert_empty tools.map(&:name).grep_v(SAFE)
    assert_match(/\Atracker__issues_list_open_\h{8}\z/, tools.first.name)
    assert_equal ["issues.list/open", long, "9lives"], client.calls
  end

  def test_a_name_that_is_already_safe_is_left_as_it_is
    client = client_for("create_issue", "list-teams")

    assert_equal %w[create_issue list-teams], Mistri::MCP.tools(client).map(&:name)
    assert_equal %w[linear__create_issue linear__list-teams],
                 Mistri::MCP.tools(client, prefix: "linear").map(&:name)
  end

  def test_a_name_never_starts_with_a_digit_or_a_hyphen
    names = Mistri::MCP.tools(client_for("9lives", "-dash")).map(&:name)

    assert_match(/\A_9lives_\h{8}\z/, names.first)
    assert_match(/\A_-dash_\h{8}\z/, names.last)
  end

  def test_a_name_depends_only_on_the_prefix_and_the_remote_name
    remotes = ["a.b", "a_b", "a/b", "export_#{"x" * 140}"]
    alone = remotes.map { |remote| Mistri::MCP.tools(client_for(remote)).first.name }

    together = Mistri::MCP.tools(client_for(*remotes)).map(&:name)
    reversed = Mistri::MCP.tools(client_for(*remotes.reverse)).map(&:name).reverse

    by_helper = remotes.map { |remote| Mistri::MCP.local_name(remote) }

    assert_equal alone, together
    assert_equal alone, reversed
    assert_equal alone, by_helper
    assert_equal 4, alone.uniq.length
    assert_equal "a_b", alone[1]
    assert_empty alone.grep_v(SAFE)
  end

  def test_a_long_name_keeps_its_start_and_is_exactly_as_long_as_allowed
    long = "export_#{"x" * 140}"

    name = Mistri::MCP.local_name(long, "tracker")

    assert_equal 64, name.length
    assert name.start_with?("tracker__export_xxx")
    refute_equal name, Mistri::MCP.local_name("#{long}y", "tracker")
  end

  def test_two_long_prefixes_that_differ_late_keep_their_tools_apart
    first = Mistri::MCP.local_name("read_resources", "#{"x" * 55}a")
    second = Mistri::MCP.local_name("read_resources", "#{"x" * 55}b")

    refute_equal first, second
    assert_empty [first, second].grep_v(SAFE)
  end

  def test_two_prefixes_that_differ_only_in_unsafe_characters_keep_their_tools_apart
    refute_equal Mistri::MCP.local_name("search", "a.b"), Mistri::MCP.local_name("search", "a/b")
  end

  def test_a_host_can_give_a_bridged_tool_a_name_of_its_own
    client = client_for("issues.list/open")

    tool = Mistri::MCP.bridge(client, client.tools.first, name: "open_issues")
    tool.call({}, nil)

    assert_equal "open_issues", tool.name
    assert_equal ["issues.list/open"], client.calls
  end
end
