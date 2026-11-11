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
    assert_equal "tracker__issues_list_open", tools.first.name
    assert_equal ["issues.list/open", long, "9lives"], client.calls
  end

  def test_a_name_that_is_already_safe_is_left_as_it_is
    client = client_for("create_issue", "list-teams")

    assert_equal %w[create_issue list-teams], Mistri::MCP.tools(client).map(&:name)
    assert_equal %w[linear__create_issue linear__list-teams],
                 Mistri::MCP.tools(client, prefix: "linear").map(&:name)
  end

  def test_a_name_without_a_prefix_never_starts_with_a_digit_or_a_hyphen
    names = Mistri::MCP.tools(client_for("9lives", "-dash")).map(&:name)

    assert_equal %w[_9lives _-dash], names
  end

  def test_two_remote_names_that_would_share_a_local_name_stay_apart
    client = client_for("a.b", "a_b", "a/b")

    first = Mistri::MCP.tools(client).map(&:name)

    assert_equal 3, first.uniq.length
    assert_equal "a_b", first[1], "the name that was already safe keeps it"
    assert_empty first.grep_v(SAFE)
    assert_equal first, Mistri::MCP.tools(client).map(&:name), "the names are the same every time"
  end

  def test_a_long_name_keeps_its_start_and_is_the_same_every_time
    long = "export_#{"x" * 140}"

    name = Mistri::MCP.tools(client_for(long), prefix: "tracker").first.name

    assert_equal 64, name.length
    assert name.start_with?("tracker__export_xxx")
    assert_equal name, Mistri::MCP.tools(client_for(long), prefix: "tracker").first.name
    refute_equal name, Mistri::MCP.tools(client_for("#{long}y"), prefix: "tracker").first.name
  end
end
