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
    UNSAFE_NAME = /[^A-Za-z0-9_-]/

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
    # (gates: { "create_issue" => true }, or needs_approval: for all).
    def tools(client, allow: nil, deny: [], prefix: nil, needs_approval: false, gates: {},
              complete_argument_validator: nil)
      listed = client.tools
      listed = listed.select { |tool| allow.include?(tool["name"]) } if allow
      listed = listed.reject { |tool| deny.include?(tool["name"]) }
      names = local_names(listed.map { |tool| tool["name"] }, prefix)
      listed.map do |tool|
        bridge(client, tool, name: names[tool["name"]],
                             gate: gates.fetch(tool["name"], needs_approval),
                             complete_argument_validator: complete_argument_validator)
      end
    end

    # The model calls the tool by name, or by a safe name made from prefix and
    # the remote name. The server is always called with the remote name.
    def bridge(client, spec, prefix: nil, name: nil, gate: false,
               complete_argument_validator: nil)
      remote = spec.fetch("name")
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
      raise ConfigurationError, "MCP tool #{remote.inspect}: #{e.message}"
    end

    # A remote name that is already safe stays as it is. Any other is made
    # safe from the remote name alone, so it is the same in every run.
    def local_name(remote, prefix = nil)
      name = (prefix ? "#{prefix}__#{remote}" : remote.to_s).gsub(UNSAFE_NAME, "_")
      name = "_#{name}" unless name.match?(/\A[A-Za-z_]/)
      name.length > NAME_LIMIT ? distinct_name(name, remote) : name
    end

    def local_names(remotes, prefix)
      names = remotes.to_h { |remote| [remote, local_name(remote, prefix)] }
      shared = names.values.tally.select { |_name, count| count > 1 }.keys
      names.to_h do |remote, name|
        kept = name == (prefix ? "#{prefix}__#{remote}" : remote)
        [remote, shared.include?(name) && !kept ? distinct_name(name, remote) : name]
      end
    end

    def distinct_name(name, remote)
      "#{name[0, NAME_LIMIT - 9]}_#{Digest::SHA256.hexdigest(remote.to_s)[0, 8]}"
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

    private_class_method :local_names, :distinct_name
  end
end

require_relative "mcp/egress"
require_relative "mcp/wires"
require_relative "mcp/client"
require_relative "mcp/oauth"

Mistri::MCP.private_constant :Egress, :WireError, :EMPTY_INPUT_SCHEMA, :NAME_LIMIT, :UNSAFE_NAME
