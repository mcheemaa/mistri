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

      # A parallel tool turn can legitimately exceed MySQL MEDIUMTEXT even
      # though each call stays inside its own input limit. Postgres text is unbounded.
      def payload_size
        adapter = ::ActiveRecord::Base.connection_db_config.adapter.to_s
        payload_size_for(adapter)
      rescue StandardError
        ""
      end

      def payload_size_for(adapter)
        adapter.to_s.match?(/mysql|trilogy/) ? ", size: :long" : ""
      end
    end
  end
end
