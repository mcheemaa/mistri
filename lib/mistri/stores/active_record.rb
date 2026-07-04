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
    #     t.text :payload, size: :medium, null: false
    #     t.timestamps
    #   end
    #
    # Reads select only (position, payload) and sort in Ruby: ORDER BY over
    # rows carrying multi-megabyte payloads exhausts MySQL's sort buffer.
    class ActiveRecord
      def initialize(model)
        @model = model
      end

      def append(id, entry)
        position = @model.where(session_id: id).maximum(:position).to_i + 1
        @model.create!(session_id: id, position: position, payload: JSON.generate(entry))
        nil
      end

      def load(id)
        @model.where(session_id: id).pluck(:position, :payload)
              .sort_by(&:first)
              .map { |_position, payload| JSON.parse(payload) }
      end
    end
  end
end
