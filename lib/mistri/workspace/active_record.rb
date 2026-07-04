# frozen_string_literal: true

module Mistri
  module Workspace
    # Documents in the host's own database, through a model class the host
    # supplies, optionally scoped (per session, per tenant). Not auto-required;
    # load it with require "mistri/workspace/active_record".
    #
    # The model needs a path column and a content column, unique on path
    # within the scope. A migration to copy:
    #
    #   create_table :mistri_documents do |t|
    #     t.string :session_id, null: false
    #     t.string :path, null: false, limit: 512
    #     t.text :content, size: :medium, null: false
    #     t.timestamps
    #   end
    #   add_index :mistri_documents, [:session_id, :path], unique: true
    class ActiveRecord
      def initialize(model, scope: {})
        @model = model
        @scope = scope
      end

      def read(path)
        @model.where(**@scope, path: path.to_s).pick(:content)
      end

      def write(path, content)
        record = @model.find_or_initialize_by(**@scope, path: path.to_s)
        record.content = content.to_s
        record.save!
        nil
      end

      def delete(path)
        @model.where(**@scope, path: path.to_s).delete_all
        nil
      end

      def list(prefix = nil)
        paths = @model.where(**@scope).pluck(:path).sort
        prefix ? paths.select { |p| p.start_with?(prefix.to_s) } : paths
      end
    end
  end
end
