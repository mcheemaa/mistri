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
      def initialize(text:, signature: nil)
        signature = Content.freeze_string(signature) if signature.is_a?(String)
        super(text: Content.freeze_string(text), signature:)
      end

      def type = :text

      def to_h = { type: :text, text:, signature: }.compact
    end

    # A model's reasoning. `signature` is the opaque payload a provider needs to
    # replay the block on a later turn; `redacted` marks reasoning a safety
    # filter hid, leaving only the signature.
    Thinking = Data.define(:thinking, :signature, :redacted) do
      def initialize(thinking:, signature: nil, redacted: false)
        signature = Content.freeze_string(signature) if signature.is_a?(String)
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

    PNG_START = "\x89PNG\r\n\x1A\n".b.freeze
    JPEG_START = "\xFF\xD8\xFF".b.freeze
    private_constant :PNG_START, :JPEG_START

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

      # The type the first bytes show, of the four that Anthropic and OpenAI
      # take, or nil. A label can be wrong, and Anthropic refuses an image
      # whose label and bytes differ, so those two are sent this type.
      def detected_mime_type
        head = data[0, 24].unpack1("m")
        if head.start_with?(PNG_START) then "image/png"
        elsif head.start_with?(JPEG_START) then "image/jpeg"
        elsif head.start_with?("GIF87a", "GIF89a") then "image/gif"
        elsif head.start_with?("RIFF") && head[8, 4] == "WEBP" then "image/webp"
        end
      end

      # What those two are sent in place of an image of any other format. It
      # is built for each request, so it speaks of the model that reads it.
      def placeholder
        "[This image is not sent to this model: its data is not a PNG, JPEG, GIF or WebP, the " \
          "formats this model takes. It is labelled #{mime_type.inspect}.]"
      end

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
        arguments = h.key?("arguments") ? h["arguments"] : {}
        ToolCall.new(id: h["id"], name: h["name"], arguments:,
                     signature: h["signature"], arguments_error: h["arguments_error"],
                     provider_call_id: h["provider_call_id"])
      else raise ArgumentError, "unknown content block type #{h["type"].inspect}"
      end
    end
  end
end
