# frozen_string_literal: true

require "rails/generators"
require "rails/generators/named_base"
require "rails/generators/active_record"

module Mistri
  module Generators
    # bin/rails generate mistri:mcp McpConnection
    #
    # Creates a host-named MCP connection model and migration: each row is
    # one server connection and carries its own OAuth flow state, so the
    # connect/callback pair works from a controller, a GraphQL mutation, or
    # anywhere else the host prefers.
    class McpGenerator < Rails::Generators::NamedBase
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      argument :name, type: :string, default: "McpConnection"

      def create_model
        template "model.rb.tt", File.join("app/models", class_path, "#{file_name}.rb")
      end

      def create_migration_file
        migration_template "migration.rb.tt",
                           File.join(db_migrate_path, "create_#{table_name}.rb")
      end

      def show_wiring
        say <<~NOTE

          Connect (from a controller, GraphQL mutation, wherever):

            connection, authorize_url = #{class_name}.connect(
              name: "Linear", url: params[:url],
              client_name: "YourApp", redirect_uri: mcp_callback_url,
            )
            redirect_to authorize_url, allow_other_host: true

          Callback:

            connection = #{class_name}.complete(state: params[:state], code: params[:code])

          Then hand its tools to an agent:

            agent = Mistri.agent("claude-opus-4-8", tools: connection.tools(prefix: "linear"))

          Tokens are encrypted; run bin/rails db:encryption:init if you have
          not set up Active Record encryption.

        NOTE
      end
    end
  end
end
