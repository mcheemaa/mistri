# frozen_string_literal: true

require "rails/generators"
require "rails/generators/named_base"
require "rails/generators/active_record"

module Mistri
  module Generators
    # bin/rails generate mistri:install AgentEntry
    #
    # Creates the session-entry model, named by the host application, and its
    # migration, ready for Mistri::Stores::ActiveRecord.
    class InstallGenerator < Rails::Generators::NamedBase
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      argument :name, type: :string, default: "MistriEntry"

      def create_model
        template "model.rb.tt", File.join("app/models", class_path, "#{file_name}.rb")
      end

      def create_migration_file
        migration_template "migration.rb.tt",
                           File.join(db_migrate_path, "create_#{table_name}.rb")
      end

      def show_wiring
        say <<~NOTE

          Wire the store with your model:

            store = Mistri::Stores::ActiveRecord.new(#{class_name})
            session = Mistri::Session.new(store: store)

          (require "mistri/stores/active_record" where you build it.)

        NOTE
      end

      private

      # MySQL TEXT caps at 64KB, which a single large tool result can blow
      # through; MEDIUMTEXT holds 16MB. Postgres text is unbounded.
      def payload_size
        adapter = ::ActiveRecord::Base.connection_db_config.adapter.to_s
        adapter.match?(/mysql|trilogy/) ? ", size: :medium" : ""
      rescue StandardError
        ""
      end
    end
  end
end
