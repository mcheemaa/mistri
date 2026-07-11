# frozen_string_literal: true

require_relative "test_helper"

begin
  require "rails/generators"
  require "rails/generators/test_case"
  require_relative "../lib/generators/mistri/install/install_generator"
rescue LoadError
  # The gem has zero runtime dependencies; generator coverage runs only where
  # Rails is installed (the rails_test bundle group).
end

if defined?(Mistri::Generators::InstallGenerator)
  # The install generator creates a host-named model and its migration.
  class TestInstallGenerator < Rails::Generators::TestCase
    tests Mistri::Generators::InstallGenerator
    destination File.expand_path("../tmp/generator_test", __dir__)
    setup :prepare_destination

    def test_the_host_names_the_model
      run_generator ["AgentEntry"]

      assert_file "app/models/agent_entry.rb", /class AgentEntry < ApplicationRecord/
      assert_migration "db/migrate/create_agent_entries.rb" do |migration|
        assert_match(/create_table :agent_entries/, migration)
        assert_match(/t\.string :session_id, null: false, index: true/, migration)
        assert_match(/t\.integer :position, null: false/, migration)
        assert_match(/t\.text :payload, null: false/, migration)
        assert_match(/add_index :agent_entries, \[:session_id, :position\], unique: true/,
                     migration)
      end
    end

    def test_the_name_defaults_when_omitted
      run_generator

      assert_file "app/models/mistri_entry.rb", /class MistriEntry/
      assert_migration "db/migrate/create_mistri_entries.rb"
    end

    def test_mysql_family_migrations_use_longtext_for_parallel_turns
      generator = Mistri::Generators::InstallGenerator.allocate

      %w[mysql2 trilogy].each do |adapter|
        assert_equal ", size: :long", generator.send(:payload_size_for, adapter), adapter
      end
      assert_equal "", generator.send(:payload_size_for, "postgresql")
    end
  end
end
