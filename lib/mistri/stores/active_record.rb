# frozen_string_literal: true

require "json"

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
      def load(id)
        @model.uncached do
          @model.where(session_id: id).pluck(:position, :payload)
                .sort_by(&:first)
                .map { |_position, payload| JSON.parse(payload) }
        end
      end
    end
  end
end
