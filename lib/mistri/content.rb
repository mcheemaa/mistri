# frozen_string_literal: true

module Mistri
  # Typed content blocks: what a message is made of. Text and thinking on
  # assistant turns, text and images on user and tool-result turns, tool calls
  # alongside them. Blocks are immutable values that compare by content,
  # pattern-match, and round-trip through #to_h / Content.from_h, so sessions
  # replay without the loop knowing block shapes.
  module Content
    # String#to_s returns self, so a caller's mutable buffer would alias into an
    # immutable block; blocks own a frozen copy instead.
    def self.freeze_string(value)
      s = value.to_s
      s.frozen? ? s : s.dup.freeze
    end

    # `signature` carries opaque provider metadata that must round-trip, such as
    # the OpenAI Responses message id and output phase.
    Text = Data.define(:text, :signature) do
      def initialize(text:, signature: nil) = super(text: Content.freeze_string(text), signature:)

      def type = :text

      def to_h = { type: :text, text:, signature: }.compact
    end

    # A model's reasoning. `signature` is the opaque payload a provider needs to
    # replay the block on a later turn; `redacted` marks reasoning a safety
    # filter hid, leaving only the signature.
    Thinking = Data.define(:thinking, :signature, :redacted) do
      def initialize(thinking:, signature: nil, redacted: false)
        super(thinking: Content.freeze_string(thinking), signature:, redacted:)
      end

      def type = :thinking

      def redacted? = redacted

      def to_h
        h = { type: :thinking, thinking: }
        h[:signature] = signature if signature
        h[:redacted] = true if redacted
        h
      end
    end

    # A base64-encoded image with its MIME type.
    Image = Data.define(:data, :mime_type) do
      # Frozen at the pack site so the initializer's ownership check skips a
      # second copy of what can be a multi-megabyte payload.
      def self.from_bytes(bytes, mime_type:) = new(data: [bytes.b].pack("m0").freeze, mime_type:)

      # Browsers, canvases, and upload pipelines hand images around as
      # data: URIs; accept them directly.
      def self.from_data_uri(uri)
        match = /\Adata:(?<mime>[^;,]+);base64,(?<data>.+)\z/m.match(uri.to_s)
        raise ArgumentError, "not a base64 data: URI" unless match

        new(data: match[:data].delete("\n").freeze, mime_type: match[:mime])
      end

      def initialize(data:, mime_type:)
        super(data: Content.freeze_string(data), mime_type: Content.freeze_string(mime_type))
      end

      def type = :image

      def bytes = data.unpack1("m0")

      def to_h = { type: :image, data:, mime_type: }
    end

    # Coerce a value into a list of blocks: nil becomes none, a String becomes
    # one Text block, blocks pass through, arrays may mix all of these.
    def self.wrap(content)
      Array(content).map do |block|
        block.respond_to?(:type) ? block : Text.new(text: block.to_s)
      end
    end

    # The inverse of #to_h, used when a session is read back. Keys may be
    # symbols or, after a JSON round-trip, strings.
    def self.from_h(hash)
      h = hash.transform_keys(&:to_s)
      case h["type"].to_s
      when "text" then Text.new(text: h["text"], signature: h["signature"])
      when "thinking"
        Thinking.new(thinking: h["thinking"], signature: h["signature"],
                     redacted: h.fetch("redacted", false))
      when "image" then Image.new(data: h["data"], mime_type: h["mime_type"])
      when "tool_call"
        ToolCall.new(id: h["id"], name: h["name"], arguments: h["arguments"] || {},
                     signature: h["signature"])
      else raise ArgumentError, "unknown content block type #{h["type"].inspect}"
      end
    end
  end
end
