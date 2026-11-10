# frozen_string_literal: true

require "json"
require_relative "../errors"

module Mistri
  module Stores
    # Entries in the host's own database, through a model class the host
    # supplies, so sessions live where application data lives: MySQL,
    # Postgres, whatever the app runs. Not auto-required; load it with
    # require "mistri/stores/active_record".
    #
    # The model needs three columns: session_id (string, indexed), position
    # (integer), payload (text). A migration to copy:
    #
    #   create_table :mistri_entries do |t|
    #     t.string :session_id, null: false, index: true
    #     t.integer :position, null: false
    #     t.text :payload, size: :long, null: false
    #     t.timestamps
    #   end
    #   add_index :mistri_entries, [:session_id, :position], unique: true
    #
    # The unique index is load-bearing: a session's loop is serial, but other
    # writers append alongside it by design (a steer from a web process, a
    # background child's report from a job), so appends are optimistic. Two
    # writers that pick the same position collide on the index and the loser
    # retries at the next one; entry order stays intact without a lock.
    #
    # Reads select only (position, payload) and sort in Ruby: ORDER BY over
    # rows carrying multi-megabyte payloads exhausts MySQL's sort buffer.
    class ActiveRecord
      # Concurrent writers converge in one or two retries; a session would
      # need this many simultaneous appenders to exhaust them.
      APPEND_ATTEMPTS = 5

      def initialize(model)
        @model = model
      end

      def append(id, entry)
        payload = JSON.generate(entry)
        attempts = 0
        begin
          position = @model.where(session_id: id).maximum(:position).to_i + 1
          @model.create!(session_id: id, position: position, payload: payload)
          nil
        rescue ::ActiveRecord::RecordNotUnique
          attempts += 1
          raise if attempts >= APPEND_ATTEMPTS

          retry
        end
      end

      # Other processes append to a session by design, and hosts poll these
      # reads inside jobs where Rails caches repeated identical queries, so
      # a cached read would never see a child's report land. Read past it.
      # Only past Rails' cache: an open REPEATABLE READ transaction still
      # pins its snapshot, so never poll from inside one.
      def load(id, from: 0)
        @model.uncached do
          rows = @model.where(session_id: id, position: (from + 1)..)
                       .pluck(:position, :payload).sort_by(&:first)
          verify_positions(id, rows, from)
          rows.map { |_position, payload| JSON.parse(payload) }
        end
      end

      # Inside a transaction a read can be rolled back or pinned to an older
      # snapshot, so a session reads the whole log there and holds nothing.
      # with_connection borrows a connection for the question; connection would
      # keep one checked out for the rest of the run.
      def settled?
        open = if @model.respond_to?(:with_connection)
                 @model.with_connection(&:transaction_open?)
               else
                 @model.connection.transaction_open?
               end
        !open
      end

      private

      # An entry's place in the log is its position minus one, so the rows of
      # one read must sit at consecutive positions from the one asked for.
      def verify_positions(id, rows, from)
        return if rows.empty?
        return if rows.first.first == from + 1 && rows.last.first == from + rows.length

        raise ConfigurationError, "session #{id.inspect} has entries that are not at " \
                                  "consecutive positions in the store"
      end
    end
  end
end
