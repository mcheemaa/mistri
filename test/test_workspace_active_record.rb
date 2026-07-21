# frozen_string_literal: true

require_relative "test_helper"

begin
  require "active_record"
  require_relative "../lib/mistri/workspace/active_record"
rescue LoadError
  # The optional adapter is exercised only when the host dependency is present.
end

if defined?(Mistri::Workspace::ActiveRecord)
  # A row-locking model double that pins adapter control flow and exception
  # classification; the separate InnoDB suite proves actual database locking.
  class AtomicDocumentModel
    # The mutable record returned by a locking read saves through its model.
    class Record
      attr_accessor :content
      attr_reader :attributes

      def initialize(model, attributes)
        @model = model
        @attributes = attributes
        @content = attributes.fetch(:content)
      end

      def save!
        @model.save!(self, @attributes)
        self
      end

      def reload
        @content = @attributes.fetch(:content)
        self
      end
    end

    # A filtered relation with the query operations the adapter owns.
    class Relation
      def initialize(model, criteria)
        @model = model
        @criteria = criteria
      end

      def pick(column)
        row = @model.find(@criteria)
        row&.fetch(column)
      end

      def exists? = !@model.find(@criteria).nil?
    end

    # A locking scope may only be read from the model's transaction.
    class Locked
      def initialize(model) = @model = model

      def find_by(**criteria)
        @model.locked_find(criteria)
      end
    end

    attr_reader :lock_reads, :saves, :transactions, :creates, :connection
    attr_accessor :save_error, :create_error, :save_transform

    Column = Data.define(:name, :null)
    Index = Data.define(:columns, :unique, :where, :valid) do
      def valid? = valid
    end
    Connection = Struct.new(:adapter_name, :transaction_open, :engine, :columns_list,
                            :indexes_list, :primary_keys_list, :database) do
      def transaction_open? = transaction_open
      def columns(_table_name) = columns_list
      def indexes(_table_name) = indexes_list
      def primary_keys(_table_name) = primary_keys_list
      def quote(value) = "'#{value}'"
      def select_value(_sql, _name) = engine
      def current_database = database
    end

    def initialize
      @rows = []
      @next_id = 0
      @mutex = Mutex.new
      @lock_reads = 0
      @saves = 0
      @transactions = 0
      @creates = 0
      columns = %w[id tenant_id path content].map { |name| Column.new(name:, null: false) }
      index = Index.new(columns: %w[tenant_id path], unique: true, where: nil, valid: true)
      @connection = Connection.new(
        "Mysql2", false, "InnoDB", columns, [index], ["id"], "test"
      )
    end

    def seed(**attributes)
      synchronize { @rows << attributes.merge(id: next_id) }
    end

    def replace(criteria, content)
      synchronize do
        row = @rows.find { |candidate| matches?(candidate, criteria) }
        row[:content] = content
      end
    end

    def where(**criteria) = Relation.new(self, criteria)
    def lock = Locked.new(self)

    def uncached
      yield
    end

    def table_name = "atomic_documents"
    def primary_key = "id"

    def transaction
      @mutex.synchronize do
        @transactions += 1
        Thread.current[transaction_key] = true
        @connection.transaction_open = true
        yield
      ensure
        Thread.current[transaction_key] = false
        @connection.transaction_open = false
      end
    end

    def create!(**attributes)
      synchronize do
        @creates += 1
        raise @create_error if @create_error
        if @rows.any? { |row| same_path?(row, attributes) }
          raise ::ActiveRecord::RecordNotUnique, "duplicate document path"
        end

        @rows << attributes.merge(id: next_id)
        Record.new(self, @rows.last)
      end
    end

    def find(criteria)
      synchronize { @rows.find { |row| matches?(row, criteria) }&.dup }
    end

    def locked_find(criteria)
      raise "locking read outside transaction" unless Thread.current[transaction_key]

      @lock_reads += 1
      row = @rows.find { |candidate| matches?(candidate, criteria) }
      row && Record.new(self, row)
    end

    def save!(record, attributes)
      raise "save outside transaction" unless Thread.current[transaction_key]

      @saves += 1
      raise @save_error if @save_error

      attributes[:content] = record.content
      @save_transform&.call(attributes)
    end

    private

    def next_id
      @next_id += 1
    end

    def transaction_key = @transaction_key ||= :"mistri_atomic_model_#{object_id}"

    def synchronize(&operation)
      Thread.current[transaction_key] ? operation.call : @mutex.synchronize(&operation)
    end

    def matches?(row, criteria)
      criteria.all? { |key, value| row[key] == value }
    end

    def same_path?(left, right)
      keys = (left.keys | right.keys) - %i[content id]
      keys.all? { |key| left[key] == right[key] }
    end
  end

  # Active Record atomic workspace behavior without coupling default CI to a DB.
  class TestWorkspaceActiveRecord < Minitest::Test
    def setup
      @model = AtomicDocumentModel.new
      @model.seed(tenant_id: 1, path: "page.html", content: "one")
      @model.seed(tenant_id: 2, path: "page.html", content: "other tenant")
      @workspace = Mistri::Workspace::ActiveRecord.new(@model, scope: { tenant_id: 1 })
    end

    def test_snapshot_and_conditional_update_stay_inside_scope
      before = @workspace.snapshot("page.html")

      after = @workspace.compare_and_write(
        "page.html", "two", expected_revision: before.revision
      )

      assert_predicate @workspace, :atomic_writes?
      assert_equal "two", after.content
      assert_equal "two", @workspace.read("page.html")
      other = @model.where(tenant_id: 2, path: "page.html").pick(:content)

      assert_equal "other tenant", other
      assert_equal 1, @model.transactions
      assert_equal 1, @model.lock_reads
      assert_equal 1, @model.saves
    end

    def test_a_stale_update_is_side_effect_free
      stale = @workspace.snapshot("page.html")
      @model.replace({ tenant_id: 1, path: "page.html" }, "newer")

      error = assert_raises(Mistri::WorkspaceConflictError) do
        @workspace.compare_and_write(
          "page.html", "stale", expected_revision: stale.revision
        )
      end

      assert_equal "page.html", error.path
      assert_equal "newer", @workspace.read("page.html")
      assert_equal 0, @model.saves
    end

    def test_nil_revision_inserts_without_a_missing_row_lock
      created = @workspace.compare_and_write("new.html", "new", expected_revision: nil)

      assert_equal "new", created.content
      assert_equal "new", @workspace.read("new.html")
      assert_equal 1, @model.creates
      assert_equal 1, @model.transactions
      assert_equal 0, @model.lock_reads
    end

    def test_exact_path_create_collision_becomes_a_workspace_conflict
      error = assert_raises(Mistri::WorkspaceConflictError) do
        @workspace.compare_and_write("page.html", "loser", expected_revision: nil)
      end

      assert_equal "page.html", error.path
      assert_equal "one", @workspace.read("page.html")
    end

    def test_an_unrelated_unique_error_is_not_mislabeled
      @model.create_error = ::ActiveRecord::RecordNotUnique.new("another unique index")

      error = assert_raises(::ActiveRecord::RecordNotUnique) do
        @workspace.compare_and_write("new.html", "new", expected_revision: nil)
      end

      assert_equal "another unique index", error.message
    end

    def test_save_and_callback_errors_are_not_mislabeled_or_retried
      before = @workspace.snapshot("page.html")
      @model.save_error = IOError.new("callback failed")

      error = assert_raises(IOError) do
        @workspace.compare_and_write(
          "page.html", "two", expected_revision: before.revision
        )
      end

      assert_equal "callback failed", error.message
      assert_equal 1, @model.saves
      assert_equal "one", @workspace.read("page.html")
    end

    def test_an_unsupported_adapter_does_not_advertise_atomicity
      @model.connection.adapter_name = "SQLite"

      refute_predicate @workspace, :atomic_writes?
      error = assert_raises(Mistri::ConfigurationError) do
        @workspace.snapshot("page.html")
      end

      assert_match(/on SQLite does not qualify/, error.message)
    end

    def test_a_non_transactional_mysql_table_does_not_advertise_atomicity
      @model.connection.engine = "MyISAM"

      refute_predicate @workspace, :atomic_writes?
      error = assert_raises(Mistri::ConfigurationError) do
        @workspace.snapshot("page.html")
      end

      assert_match(/InnoDB/, error.message)
    end

    def test_an_unknown_mysql_engine_does_not_advertise_atomicity
      @model.connection.engine = nil

      refute_predicate @workspace, :atomic_writes?
    end

    def test_a_missing_unique_scope_path_key_does_not_advertise_atomicity
      @model.connection.indexes_list = []

      refute_predicate @workspace, :atomic_writes?
      assert_raises(Mistri::ConfigurationError) { @workspace.snapshot("page.html") }
    end

    def test_expression_and_invalid_indexes_do_not_mask_a_valid_identity_index
      expression = AtomicDocumentModel::Index.new(
        columns: "lower(path)", unique: true, where: nil, valid: true
      )
      invalid = AtomicDocumentModel::Index.new(
        columns: %w[tenant_id path], unique: true, where: nil, valid: false
      )
      valid = AtomicDocumentModel::Index.new(
        columns: %w[tenant_id path], unique: true, where: nil, valid: true
      )
      @model.connection.indexes_list = [expression, invalid, valid]

      assert_predicate @workspace, :atomic_writes?
    end

    def test_an_invalid_unique_index_does_not_advertise_atomicity
      @model.connection.indexes_list = [
        AtomicDocumentModel::Index.new(
          columns: %w[tenant_id path], unique: true, where: nil, valid: false
        )
      ]

      refute_predicate @workspace, :atomic_writes?
    end

    def test_nullable_identity_or_content_does_not_advertise_atomicity
      @model.connection.columns_list = [
        AtomicDocumentModel::Column.new(name: "tenant_id", null: false),
        AtomicDocumentModel::Column.new(name: "path", null: true),
        AtomicDocumentModel::Column.new(name: "content", null: false)
      ]

      refute_predicate @workspace, :atomic_writes?
      assert_raises(Mistri::ConfigurationError) { @workspace.snapshot("page.html") }
    end

    def test_a_model_without_a_primary_key_does_not_advertise_atomicity
      @model.define_singleton_method(:primary_key) { nil }

      refute_predicate @workspace, :atomic_writes?
      assert_raises(Mistri::ConfigurationError) { @workspace.snapshot("page.html") }
    end

    def test_a_cached_capability_still_defends_against_primary_key_mutation
      before = @workspace.snapshot("page.html")
      @model.define_singleton_method(:primary_key) { nil }

      error = assert_raises(Mistri::ConfigurationError) do
        @workspace.compare_and_write(
          "page.html", "two", expected_revision: before.revision
        )
      end

      assert_match(/needs a primary key/, error.message)
    end

    def test_model_metadata_cannot_invent_a_database_primary_key
      @model.define_singleton_method(:primary_key) { %w[tenant_id path] }
      @model.connection.indexes_list = []

      refute_predicate @workspace, :atomic_writes?
    end

    def test_a_multi_value_scope_does_not_advertise_one_document_atomicity
      workspace = Mistri::Workspace::ActiveRecord.new(
        @model, scope: { tenant_id: [1, 2] }
      )

      refute_predicate workspace, :atomic_writes?
      assert_raises(Mistri::ConfigurationError) { workspace.snapshot("page.html") }
    end

    def test_a_range_scope_is_owned_but_does_not_advertise_atomicity
      first = +"a"
      last = +"b"
      workspace = Mistri::Workspace::ActiveRecord.new(
        @model, scope: { tenant_id: (first..last) }
      )
      first.replace("x")
      last.replace("y")

      refute_predicate workspace, :atomic_writes?
    end

    def test_a_custom_mutable_scope_value_does_not_advertise_atomicity
      tenant = Struct.new(:value).new(1)
      workspace = Mistri::Workspace::ActiveRecord.new(
        @model, scope: { tenant_id: tenant }
      )

      refute_predicate workspace, :atomic_writes?
    end

    def test_document_columns_cannot_be_reused_as_scope
      %i[path content].each do |column|
        error = assert_raises(ArgumentError) do
          Mistri::Workspace::ActiveRecord.new(@model, scope: { column => "value" })
        end

        assert_match(/scope cannot contain/, error.message)
      end
    end

    def test_scope_cannot_name_one_column_twice
      error = assert_raises(ArgumentError) do
        Mistri::Workspace::ActiveRecord.new(
          @model, scope: { tenant_id: 1, "tenant_id" => 2 }
        )
      end

      assert_match(/distinct columns/, error.message)
    end

    def test_composite_primary_identity_cannot_follow_a_moved_document
      @model.define_singleton_method(:primary_key) { %w[tenant_id path] }
      @model.connection.primary_keys_list = %w[tenant_id path]
      @model.connection.indexes_list = []
      @model.save_transform = ->(attributes) { attributes[:path] = "moved.html" }
      before = @workspace.snapshot("page.html")

      error = assert_raises(Mistri::SchemaError) do
        @workspace.compare_and_write(
          "page.html", "two", expected_revision: before.revision
        )
      end

      assert_match(/changed identity/, error.message)
    end

    def test_scope_is_owned_at_construction
      tenant = +"tenant-a"
      scope = { tenant_id: tenant }
      @model.seed(tenant_id: "tenant-a", path: "scoped.html", content: "a")
      @model.seed(tenant_id: "tenant-b", path: "scoped.html", content: "b")
      workspace = Mistri::Workspace::ActiveRecord.new(@model, scope:)
      tenant.replace("tenant-b")
      scope[:tenant_id] = "tenant-b"

      before = workspace.snapshot("scoped.html")
      workspace.compare_and_write("scoped.html", "a2", expected_revision: before.revision)

      first = @model.where(tenant_id: "tenant-a", path: "scoped.html").pick(:content)
      second = @model.where(tenant_id: "tenant-b", path: "scoped.html").pick(:content)

      assert_equal "a2", first
      assert_equal "b", second
    end

    def test_atomic_operations_reject_an_external_transaction
      @model.connection.transaction_open = true

      error = assert_raises(Mistri::ConfigurationError) do
        @workspace.snapshot("page.html")
      end

      assert_match(/cannot join an open transaction/, error.message)
    ensure
      @model.connection.transaction_open = false
    end
  end
end

if defined?(Mistri::Workspace::ActiveRecord)
  # The smallest model that can lie the way Rails' query cache lies: while
  # caching, identical reads serve the first snapshot until an uncached
  # window bypasses it. Writes here stand for another process's writes, so
  # they do not clear the cache.
  class CachingDocumentModel
    class Relation
      def initialize(rows) = @rows = rows

      def pick(column) = @rows.first&.fetch(column, nil)

      def pluck(column) = @rows.map { |row| row.fetch(column) }
    end

    def initialize
      @rows = []
      @caching = false
      @cache = nil
    end

    def insert_out_of_band(path, content)
      @rows << { path: path, content: content }
    end

    def cache
      @caching = true
      yield
    ensure
      @caching = false
      @cache = nil
    end

    def uncached
      was_caching = @caching
      @caching = false
      yield
    ensure
      @caching = was_caching
    end

    def where(**criteria)
      if @caching
        @cache ||= {}
        return Relation.new(@cache[criteria] ||= select_rows(criteria))
      end

      Relation.new(select_rows(criteria))
    end

    private

    def select_rows(criteria)
      path = criteria[:path]
      path ? @rows.select { |row| row[:path] == path }.dup : @rows.dup
    end
  end

  class TestWorkspaceQueryCache < Minitest::Test
    def setup
      @model = CachingDocumentModel.new
      @workspace = Mistri::Workspace::ActiveRecord.new(@model)
    end

    def test_read_sees_writes_from_other_processes_despite_the_query_cache
      @model.cache do
        assert_nil @workspace.read("index.html")

        @model.insert_out_of_band("index.html", "<h1>Draft</h1>")

        assert_equal "<h1>Draft</h1>", @workspace.read("index.html")
      end
    end

    def test_list_sees_writes_from_other_processes_despite_the_query_cache
      @model.cache do
        assert_empty @workspace.list

        @model.insert_out_of_band("notes.md", "notes")

        assert_equal ["notes.md"], @workspace.list
      end
    end
  end
end
