# frozen_string_literal: true

require_relative "../test_helper"

url = ENV.fetch("MISTRI_POSTGRES_URL", nil)
abort "MISTRI_POSTGRES_URL is required for the PostgreSQL session store suite" if url.to_s.empty?

require "active_record"
require "pg"
require_relative "../../lib/mistri/stores/active_record"
require_relative "session_store_tests"

ActiveRecord::Base.establish_connection(url)
connection = ActiveRecord::Base.connection
connection.create_table(:mistri_postgresql_entries, force: true) do |t|
  t.string :session_id, null: false
  t.integer :position, null: false
  t.text :payload, null: false
  t.timestamps
end
connection.add_index(:mistri_postgresql_entries, %i[session_id position], unique: true)

class PostgresqlSessionEntry < ActiveRecord::Base
  self.table_name = "mistri_postgresql_entries"
end

class TestSessionStorePostgresql < Minitest::Test
  include SessionStoreTests

  def model = PostgresqlSessionEntry
end
