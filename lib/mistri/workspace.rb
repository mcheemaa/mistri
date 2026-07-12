# frozen_string_literal: true

require "digest"
require_relative "errors"

module Mistri
  # The host-neutral document boundary. Every workspace supports ordinary
  # read/write/delete/list; atomic_writes? opts into snapshot and conditional
  # write semantics that remain correct across processes when its backend does.
  module Workspace
    MAX_REVISION_BYTES = 256
    private_constant :MAX_REVISION_BYTES

    # One immutable document representation and the opaque token that binds a
    # later conditional write to these exact bytes.
    Snapshot = Data.define(:content, :revision) do
      def initialize(content:, revision:)
        raise ArgumentError, "snapshot content must be a String" unless content.is_a?(String)
        raise ArgumentError, "snapshot revision must be a String" unless revision.is_a?(String)

        owned_content = String.new(content)
        owned_revision = String.new(revision)
        unless !owned_revision.empty? && owned_revision.bytesize <= MAX_REVISION_BYTES
          raise ArgumentError,
                "snapshot revision must be 1-#{MAX_REVISION_BYTES} bytes"
        end

        super(content: owned_content.freeze, revision: owned_revision.freeze)
      end

      def self.for(content)
        raise ArgumentError, "snapshot content must be a String" unless content.is_a?(String)

        owned = String.new(content)
        new(content: owned, revision: Digest::SHA256.hexdigest(owned.b))
      end
    end
  end
end
