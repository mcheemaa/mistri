# frozen_string_literal: true

module Mistri
  # One message in a conversation, the single shape every provider translates to
  # and from its wire format. Immutable: streaming builds snapshots, sessions
  # replay values, and nothing aliases across threads.
  #
  # Roles: :system, :user, :assistant, :tool (a tool result linked back by
  # tool_call_id). Assistant messages carry the model and provider that produced
  # them, which is what lets a later turn replay history across models, plus
  # usage and the stop reason.
  #
  # ui is a tool result's host-only channel: it persists with the message and
  # rides its :tool_result event, but no serializer ever sends it to a model.
  class Message < Data.define(:role, :content, :tool_call_id, :tool_name,
                              :model, :provider, :usage, :stop_reason, :error_message, :ui)
    ROLES = %i[system user assistant tool].freeze

    def initialize(role:, content: nil, tool_call_id: nil, tool_name: nil, model: nil,
                   provider: nil, usage: nil, stop_reason: nil, error_message: nil, ui: nil)
      role = role.to_sym
      raise ArgumentError, "unknown role #{role.inspect}" unless ROLES.include?(role)
      if stop_reason && !StopReason.valid?(stop_reason)
        raise ArgumentError, "unknown stop reason #{stop_reason.inspect}"
      end

      super(role:, content: Content.wrap(content).freeze, tool_call_id:, tool_name:,
            model:, provider:, usage:, stop_reason:, error_message:, ui:)
    end

    def self.system(content) = new(role: :system, content:)

    def self.user(content) = new(role: :user, content:)

    # A user turn carrying images alongside optional text.
    def self.user_with_images(content, images = [])
      images = Array(images)
      return user(content) if images.empty?

      text = content.to_s
      blocks = text.empty? ? images : [Content::Text.new(text:), *images]
      new(role: :user, content: blocks)
    end

    def self.assistant(content: nil, tool_calls: [], **meta)
      new(role: :assistant, content: [*Content.wrap(content), *tool_calls], **meta)
    end

    def self.tool(content:, tool_call_id:, tool_name: nil, ui: nil)
      new(role: :tool, content:, tool_call_id:, tool_name:, ui:)
    end

    def self.from_h(hash)
      h = hash.transform_keys(&:to_s)
      new(role: h.fetch("role").to_sym,
          content: Array(h["content"]).map { |block| Content.from_h(block) },
          tool_call_id: h["tool_call_id"], tool_name: h["tool_name"],
          model: h["model"], provider: h["provider"]&.to_sym,
          usage: h["usage"] && Usage.from_h(h["usage"]),
          stop_reason: h["stop_reason"]&.to_sym, error_message: h["error_message"],
          ui: h["ui"])
    end

    def system? = role == :system
    def user? = role == :user
    def assistant? = role == :assistant
    def tool? = role == :tool

    # Every Text block joined, or nil when the turn carried no text.
    def text
      texts = content.grep(Content::Text)
      texts.empty? ? nil : texts.map(&:text).join
    end

    def tool_calls = content.grep(ToolCall)

    def tool_calls? = content.any?(ToolCall)

    # A serialization shape, not the member hash: rebuild with .from_h,
    # never with new(**to_h).
    def to_h
      { role:, content: content.map(&:to_h), tool_call_id:, tool_name:, model:,
        provider:, usage: usage&.to_h, stop_reason:, error_message:, ui: }.compact
    end
  end
end
