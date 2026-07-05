# frozen_string_literal: true

require_relative "test_helper"

begin
  require "rails/generators"
  require "rails/generators/test_case"
  require_relative "../lib/generators/mistri/mcp/mcp_generator"
rescue LoadError
  # Generator coverage runs only where Rails is installed (rails_test group).
end

if defined?(Mistri::Generators::McpGenerator)
  # The MCP connection generator: host-named model whose rows carry their
  # own OAuth flow state and bridge into agent tools.
  class TestMcpGenerator < Rails::Generators::TestCase
    tests Mistri::Generators::McpGenerator
    destination File.expand_path("../tmp/mcp_generator_test", __dir__)
    setup :prepare_destination

    def test_the_host_names_the_connection_model
      run_generator ["ToolConnection"]

      assert_file "app/models/tool_connection.rb" do |model|
        assert_match(/class ToolConnection < ApplicationRecord/, model)
        assert_match(/encrypts :access_token, :refresh_token, :client_secret/, model)
        assert_match(/Mistri::MCP::OAuth\.start/, model)
        assert_match(/def tools/, model)
      end
      assert_migration "db/migrate/create_tool_connections.rb" do |migration|
        assert_match(/t\.string :state/, migration)
        assert_match(/t\.text :access_token/, migration)
        assert_match(/add_index :tool_connections, :state, unique: true/, migration)
      end
    end

    def test_the_name_defaults_when_omitted
      run_generator

      assert_file "app/models/mcp_connection.rb", /class McpConnection/
      assert_migration "db/migrate/create_mcp_connections.rb"
    end
  end
end
