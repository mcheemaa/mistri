# frozen_string_literal: true

require_relative "../test_helper"

url = ENV.fetch("MISTRI_MYSQL_URL", nil)
abort "MISTRI_MYSQL_URL is required for the MySQL session store suite" if url.to_s.empty?

require "active_record"
require "mysql2"
require_relative "../../lib/mistri/stores/active_record"
require_relative "session_store_tests"

ActiveRecord::Base.establish_connection(url)
connection = ActiveRecord::Base.connection
connection.create_table(:mistri_mysql_entries, force: true, options: "ENGINE=InnoDB") do |t|
  t.string :session_id, null: false
  t.integer :position, null: false
  t.text :payload, size: :long, null: false
  t.timestamps
end
connection.add_index(:mistri_mysql_entries, %i[session_id position], unique: true)

class MysqlSessionEntry < ActiveRecord::Base
  self.table_name = "mistri_mysql_entries"
end

class TestSessionStoreMysql < Minitest::Test
  include SessionStoreTests

  def model = MysqlSessionEntry
end
