# frozen_string_literal: true

require_relative "../workspace"

module Mistri
  module Workspace
    # Documents in the host's own database, through a model class the host
    # supplies, optionally scoped (per session, per tenant). Not auto-required;
    # load it with require "mistri/workspace/active_record".
    #
    # The model needs a non-null primary key plus non-null path, content, and
    # scope columns, with a unique index whose columns are exactly the scope
    # plus path. Atomic edits use that index plus a short row-locking
    # transaction; no lock_version column is required. A migration to copy:
    #
    #   create_table :mistri_documents do |t|
    #     t.string :session_id, null: false
    #     t.string :path, null: false, limit: 512
    #     t.text :content, size: :medium, null: false
    #     t.timestamps
    #   end
    #   add_index :mistri_documents, [:session_id, :path], unique: true
    #
    # Reads run uncached: other processes write documents by design, and a
    # cached read inside a job would serve the job's first snapshot forever.
    # Uncached only defeats Rails' cache; an open REPEATABLE READ transaction
    # still pins what reads see, so do not read from inside one.
    class ActiveRecord
      MYSQL_ADAPTERS = %w[Mysql2 Trilogy].freeze
      private_constant :MYSQL_ADAPTERS

      def initialize(model, scope: {})
        raise ArgumentError, "scope must be a Hash" unless scope.is_a?(Hash)

        names = scope.keys.map(&:to_s)
        if names.uniq.length != names.length
          raise ArgumentError, "scope keys must name distinct columns"
        end

        reserved = names & %w[path content]
        unless reserved.empty?
          raise ArgumentError, "scope cannot contain #{reserved.map(&:inspect).join(" or ")}"
        end

        @model = model
        @scope = own_scope(scope)
      end

      def read(path)
        @model.uncached { @model.where(**@scope, path: path.to_s).pick(:content) }
      end

      def write(path, content)
        record = @model.find_or_initialize_by(**@scope, path: path.to_s)
        record.content = content.to_s
        record.save!
        nil
      end

      def atomic_writes?
        return @atomic_writes if defined?(@atomic_writes)

        @atomic_writes = atomic_storage?
      end

      def snapshot(path)
        verify_atomic_context!
        content = @model.uncached { relation(path).pick(:content) }
        content.nil? ? nil : Snapshot.for(content.to_s)
      end

      def compare_and_write(path, content, expected_revision:)
        verify_atomic_context!
        key = path.to_s
        return create_if_absent(key, content) if expected_revision.nil?

        @model.transaction do
          record = @model.lock.find_by(**@scope, path: key)
          actual = record && Snapshot.for(record.content.to_s).revision
          unless actual == expected_revision
            raise WorkspaceConflictError.new(
              key, expected_revision:, actual_revision: actual
            )
          end

          record.content = content.to_s
          record.save!
          committed_snapshot(record, key)
        end
      end

      def delete(path)
        @model.where(**@scope, path: path.to_s).delete_all
        nil
      end

      def list(prefix = nil)
        paths = @model.uncached { @model.where(**@scope).pluck(:path) }.sort
        prefix ? paths.select { |p| p.start_with?(prefix.to_s) } : paths
      end

      private

      def verify_atomic_context!
        unless atomic_writes?
          adapter = @model.connection.adapter_name
          raise ConfigurationError,
                "atomic Active Record workspace writes require PostgreSQL or InnoDB, " \
                "a matching non-null primary key, non-null scope/path/content columns, " \
                "and an exact unique scope/path key; #{@model.table_name.inspect} on " \
                "#{adapter} does not qualify"
        end
        return unless @model.connection.transaction_open?

        raise ConfigurationError,
              "atomic Active Record workspace operations cannot join an open transaction"
      end

      def relation(path) = @model.where(**@scope, path: path.to_s)

      def create_if_absent(path, content)
        @model.transaction do
          record = @model.create!(**@scope, path:, content: content.to_s)
          committed_snapshot(record, path)
        end
      rescue ::ActiveRecord::RecordNotUnique
        raise unless relation(path).exists?

        actual = snapshot(path)&.revision
        raise WorkspaceConflictError.new(path, actual_revision: actual)
      end

      def atomic_storage?
        adapter = @model.connection.adapter_name
        supported = adapter == "PostgreSQL" ||
                    (MYSQL_ADAPTERS.include?(adapter) && innodb_table?)
        supported && atomic_schema?
      end

      def innodb_table?
        connection = @model.connection
        database, table = mysql_table_coordinates(connection)
        sql = "SELECT ENGINE FROM information_schema.TABLES " \
              "WHERE TABLE_SCHEMA = #{connection.quote(database)} " \
              "AND TABLE_NAME = #{connection.quote(table)}"
        connection.select_value(sql, "SCHEMA")&.casecmp?("InnoDB") == true
      end

      def mysql_table_coordinates(connection)
        names = @model.table_name.to_s.split(".", 2)
        return names if names.length == 2

        [connection.current_database, names.first]
      end

      def atomic_schema?
        connection = @model.connection
        columns = connection.columns(@model.table_name).to_h { |column| [column.name, column] }
        primary_columns = Array(@model.primary_key).compact.map(&:to_s)
        catalog_primary = Array(connection.primary_keys(@model.table_name)).map(&:to_s)
        return false unless primary_columns.sort == catalog_primary.sort
        return false if primary_columns.empty? || !singular_scope?

        required_columns = (@scope.keys.map(&:to_s) + %w[path content]).uniq
        required_columns.concat(primary_columns).uniq!
        return false unless non_null_columns?(columns, required_columns)

        identity = (@scope.keys.map(&:to_s) + ["path"]).uniq.sort
        return true if catalog_primary.sort == identity

        exact_unique_identity?(connection, identity)
      end

      def exact_unique_identity?(connection, identity)
        connection.indexes(@model.table_name).any? do |index|
          valid = !index.respond_to?(:valid?) || index.valid?
          columns = Array(index.columns).map(&:to_s).sort
          index.unique && valid && !index.where && columns == identity
        end
      end

      def non_null_columns?(columns, required)
        required.all? do |name|
          column = columns[name]
          column && !column.null
        end
      end

      def committed_snapshot(record, path)
        identity = Array(@model.primary_key).compact.to_h do |column|
          attributes = record.attributes
          value = attributes.fetch(column.to_s) { attributes.fetch(column.to_sym) }
          [column.to_sym, value]
        end
        if identity.empty?
          raise ConfigurationError, "atomic Active Record workspace needs a primary key"
        end

        content = @model.where(**identity, **@scope, path:).pick(:content)
        if content.nil?
          raise SchemaError, "document #{path.inspect} changed identity during its write"
        end

        Snapshot.for(content.to_s)
      end

      def singular_scope?
        @scope.values.all? do |value|
          case value
          when String, Symbol, Numeric, TrueClass, FalseClass, Time then true
          else defined?(Date) && value.is_a?(Date)
          end
        end
      end

      def own_scope(value)
        case value
        when Hash
          value.to_h { |key, item| [own_scope(key), own_scope(item)] }.freeze
        when Array
          value.map { |item| own_scope(item) }.freeze
        when Range
          Range.new(own_scope(value.begin), own_scope(value.end), value.exclude_end?).freeze
        when String
          String.new(value).freeze
        else
          value
        end
      end
    end
  end
end
