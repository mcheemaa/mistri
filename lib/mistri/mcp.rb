# frozen_string_literal: true

require "digest"
require "json"

module Mistri
  # Bridge Model Context Protocol servers into Mistri tools: list a server's
  # tools, hand them to an agent, and everything the harness already does
  # composes: approval gates on third-party write tools, retries, sub-agent
  # pools, the ui channel.
  #
  #   client = Mistri::MCP::Client.new(url: "https://mcp.linear.app/mcp",
  #                                    token: -> { connection.fresh_token })
  #   agent = Mistri.agent("claude-opus-5-5",
  #                        tools: Mistri::MCP.tools(client, prefix: "linear"))
  #
  # The bridge is duck-typed: any client responding to tools (an array of
  # {"name", "description", "inputSchema"} hashes) and call_tool(name, args)
  # bridges the same way, so the official mcp gem's client plugs in too.
  module MCP
    EMPTY_INPUT_SCHEMA = {
      "type" => "object", "properties" => {}.freeze, "additionalProperties" => false
    }.freeze
    # What every catalogued provider takes for a tool name: letters, digits,
    # underscores and hyphens, 64 at most, not starting with a digit or hyphen.
    NAME_LIMIT = 64
    SAFE_NAME = /\A[A-Za-z_][A-Za-z0-9_-]{0,63}\z/

    # A protocol-level failure: a JSON-RPC error, a missing response, an
    # unsupported negotiation.
    class Error < Mistri::Error
      attr_reader :code

      def initialize(message = nil, code: nil)
        @code = code
        super(message)
      end
    end

    # The stdio peer failed while a protocol message was in flight.
    class WireError < Error; end

    # The server expired this client's session (a 404 with a session
    # attached); the spec says start a fresh one, and Client does.
    class SessionExpired < Error; end

    # A remote URL cannot be used without weakening the MCP network boundary.
    class UnsafeURLError < ConfigurationError; end

    module_function

    # The server's tools as Mistri tools. allow/deny filter by remote name,
    # prefix namespaces local names ("linear__create_issue") against
    # collisions, and gates marks tools needing human approval
    # (gates: { "create_issue" => true }, or needs_approval: for all). A tool
    # that cannot be bridged is left out: the block is given its definition
    # and the error, and without a block it is named in a warning.
    def tools(client, allow: nil, deny: [], prefix: nil, needs_approval: false, gates: {},
              complete_argument_validator: nil)
      taken = {}
      client.tools.filter_map do |tool|
        remote = tool["name"] if tool.is_a?(Hash)
        next if deny.include?(remote) || (allow && !allow.include?(remote))

        bridged = bridge(client, tool, prefix: prefix, gate: gates.fetch(remote, needs_approval),
                                       complete_argument_validator: complete_argument_validator)
        claim(taken, bridged.name, remote)
        bridged
      rescue ConfigurationError => e
        block_given? ? yield(tool, e) : warn("mistri: #{e.message}; the tool was left out")
        nil
      end
    end

    def claim(taken, local, remote)
      holder = taken[local]
      if holder
        raise ConfigurationError,
              "MCP tool #{label(remote)}: the name #{local.inspect} is taken by #{label(holder)}"
      end

      taken[local] = remote
    end
    private_class_method :claim

    # A remote name is the server's to choose, so a message carries its start.
    def label(remote) = remote.inspect[0, 120]
    private_class_method :label

    # The model calls the tool by name, or by a safe name made from prefix and
    # the remote name. The server is always called with the remote name.
    def bridge(client, spec, prefix: nil, name: nil, gate: false,
               complete_argument_validator: nil)
      raise ConfigurationError, "the definition is not an object" unless spec.is_a?(Hash)

      remote = spec["name"]
      unless remote.is_a?(String) && !remote.empty?
        raise ConfigurationError, "the definition has no name"
      end

      local = name || local_name(remote, prefix)
      if spec.key?("inputSchema") && spec["inputSchema"].nil?
        raise ConfigurationError, "inputSchema must be an object, not null"
      end

      raw_schema = spec.fetch("inputSchema", EMPTY_INPUT_SCHEMA)
      input_schema = Schema.validate_mcp!(
        raw_schema, complete: !complete_argument_validator.nil?
      )
      Tool.define(local, spec["description"].to_s,
                  input_schema: input_schema,
                  needs_approval: gate,
                  complete_argument_validator: complete_argument_validator) do |args|
        answer(client.call_tool(remote, args || {}))
      end
    rescue ConfigurationError => e
      raise ConfigurationError, "MCP tool #{label(remote)}: #{e.message}"
    end

    # The local name of a remote tool. One that every provider takes stays
    # as it is. Any other has its unsafe characters replaced and ends in a
    # hash of the whole name, so it depends on nothing but prefix and remote.
    def local_name(remote, prefix = nil)
      whole = prefix ? "#{prefix}__#{remote}" : remote.to_s
      return whole if whole.match?(SAFE_NAME)

      safe = whole.gsub(/[^A-Za-z0-9_-]/, "_")
      safe = "_#{safe}" unless safe.match?(/\A[A-Za-z_]/)
      "#{safe[0, NAME_LIMIT - 9]}_#{Digest::SHA256.hexdigest(whole)[0, 8]}"
    end

    # An MCP result becomes model-readable content: text joins, images ride
    # as image blocks, and isError remains structured failure data end to end.
    def answer(result)
      blocks = Array(result["content"]).map { |block| convert(block) }
      if result["isError"]
        text_blocks = blocks.grep(String)
        if result["structuredContent"]
          structured = JSON.generate(result["structuredContent"])
          text_blocks << structured unless text_blocks.include?(structured)
        end
        text = text_blocks.join("\n")
        content = "MCP tool error: #{text.empty? ? "unknown error" : text}"
        non_text = blocks.grep_v(String)
        content = [content, *non_text] unless non_text.empty?
        return ToolResult.new(content:, error: true)
      end
      if blocks.empty? && result["structuredContent"]
        return JSON.generate(result["structuredContent"])
      end
      return blocks.join("\n") if blocks.all?(String)

      blocks
    end

    def convert(block)
      case block["type"]
      when "text" then block["text"].to_s
      when "image"
        Content::Image.from_bytes(block["data"].to_s.unpack1("m"),
                                  mime_type: block["mimeType"] || "image/png")
      when "resource" then resource_text(block["resource"] || {})
      when "resource_link" then "[resource: #{block["uri"]}]"
      else "[unsupported #{block["type"]} content]"
      end
    end

    def resource_text(resource)
      resource["text"] || "[resource: #{resource["uri"]}]"
    end
  end
end

require_relative "mcp/egress"
require_relative "mcp/wires"
require_relative "mcp/client"
require_relative "mcp/oauth"

Mistri::MCP.private_constant :Egress, :WireError, :EMPTY_INPUT_SCHEMA, :NAME_LIMIT, :SAFE_NAME
