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
    # A server that keeps sending and never answers restarts the read timeout
    # with every message, so one call is bounded in all.
    CALL_TIMEOUT = 300
    READ_RESOURCE = "read_resource"
    READ_RESOURCE_SCHEMA = {
      "type" => "object", "additionalProperties" => false, "required" => ["uri"],
      "properties" => { "uri" => { "type" => "string",
                                   "description" => "The resource's URI, as a result gave it." } }
    }.freeze
    # A type whose bytes are text a model can read.
    TEXT_TYPE = %r{\A(?:text/|application/(?:json|xml|yaml)\b|[^;]*\+(?:json|xml)\b)}i
    # Characters of a tool's description that reach the model. A description
    # is text from the server that the model reads as guidance.
    DESCRIPTION_LIMIT = 4_096

    # A protocol-level failure: a JSON-RPC error, a missing response, an
    # unsupported negotiation.
    class Error < Mistri::Error
      attr_reader :code, :data

      def initialize(message = nil, code: nil, data: nil)
        @code = code
        @data = data
        super(message)
      end
    end

    # The stdio peer failed while a protocol message was in flight.
    class WireError < Error; end

    # The server took longer than the read timeout to send a message or to
    # take one. The server, or its session, is kept.
    class WireTimeout < WireError; end

    # The server expired this client's session (a 404 with a session
    # attached); the spec says start a fresh one, and Client does.
    class SessionExpired < Error; end

    # A remote URL cannot be used without weakening the MCP network boundary.
    class UnsafeURLError < ConfigurationError; end

    # Tags the copy of an error that Client#call_tool raises before it sends
    # the call: no connection could be established, so the tool did not run.
    module NotSent; end

    module_function

    # The server's tools as Mistri tools. allow/deny filter by remote name,
    # prefix namespaces local names ("linear__create_issue") against
    # collisions, and gates marks tools needing human approval
    # (gates: { "create_issue" => true }, or needs_approval: for all). A tool
    # that cannot be bridged is left out: the block is given its definition
    # and the error, and without a block it is named in a warning. deferred
    # keeps the server's tools out of the model's sight until a search loads
    # them. instructions: false keeps the server's instructions out of the
    # conversation, and a string is sent in their place. parallel says which
    # tools may run beside others in a turn: nil follows each tool's
    # readOnlyHint, true or false sets every tool, and a hash sets tools by
    # remote name and leaves the rest to their hint. trust_hints: false means
    # no tool is marked by its hint, only by parallel. timeout is the seconds
    # one call may take in all before the agent stops waiting for it, and nil
    # sets no limit. description_limit is the characters of a description that
    # reach the model, and nil sets none. instructions_as: :user sends the
    # instructions as text of a user turn where they would be a system message.
    #
    # A server that has resources gets one more tool, read_resource, which
    # reads one by its URI: a result of the server's tools names them.
    # resources: true offers it for a server that declares none, and false
    # leaves it out. It is gated by gates: { "read_resource" => true }.
    def tools(client, allow: nil, deny: [], prefix: nil, needs_approval: false, gates: {},
              complete_argument_validator: nil, deferred: false, instructions: true,
              parallel: nil, timeout: CALL_TIMEOUT, description_limit: DESCRIPTION_LIMIT,
              instructions_as: :system, trust_hints: true, resources: nil)
      taken = {}
      listed = client.tools
      known_marks!(parallel, listed)
      instructions = instructions_for(client, instructions)
      reader = reader_name(client, listed, resources, prefix)
      bridged = listed.filter_map do |tool|
        remote = tool["name"] if tool.is_a?(Hash)
        next if deny.include?(remote) || (allow && !allow.include?(remote))

        bridged = bridge(client, tool, prefix: prefix, gate: gates.fetch(remote, needs_approval),
                                       complete_argument_validator: complete_argument_validator,
                                       deferred: deferred, instructions: instructions,
                                       parallel: parallel.is_a?(Hash) ? parallel[remote] : parallel,
                                       timeout: timeout, description_limit: description_limit,
                                       instructions_as: instructions_as, trust_hints: trust_hints,
                                       reader: reader)
        claim(taken, bridged.name, remote)
        bridged
      rescue ConfigurationError => e
        block_given? ? yield(tool, e) : warn("mistri: #{e.message}; the tool was left out")
        nil
      end
      return bridged unless reader

      bridged << resource_reader(client, reader, prefix: prefix, deferred: deferred,
                                                 gate: gates.fetch(READ_RESOURCE, needs_approval),
                                                 instructions: instructions, timeout: timeout,
                                                 instructions_as: instructions_as)
    end

    # The local name of the tool that reads this server's resources, or nil
    # when none is offered. A server's own tool of that name keeps it.
    def reader_name(client, listed, choice, prefix)
      return unless client.respond_to?(:read_resource)
      return if choice == false
      return unless choice || (client.respond_to?(:resources?) && client.resources?)

      name = local_name(READ_RESOURCE, prefix)
      own = listed.grep(Hash).any? { |tool| local_name(tool["name"], prefix) == name }
      name unless own
    end
    private_class_method :reader_name

    def resource_reader(client, local, prefix:, gate:, deferred:, instructions:, timeout:,
                        instructions_as:)
      server = prefix ? "the MCP server #{prefix.to_s.inspect}" : "the MCP server"
      Tool.define(local, "Reads one resource of #{server} by its URI. A result of this " \
                         "server's tools names a resource it can be read from.",
                  input_schema: READ_RESOURCE_SCHEMA, parallel: true, needs_approval: gate,
                  deferred: deferred, instructions: instructions, timeout: timeout,
                  instructions_as: instructions_as) do |args, context|
        contents = client.read_resource(args.fetch("uri"))
        several = contents.length > 1
        blocks = contents.grep(Hash).flat_map do |content|
          [({ "type" => "text", "text" => "#{content["uri"]}:" } if several),
           { "type" => "resource", "resource" => content }].compact
        end
        shown({ "content" => blocks }, nil, saver(context, local))
      rescue Mistri::Error => e
        ToolResult.new(content: "#{local} could not read the resource from #{server}: " \
                                "#{e.message}", error: true)
      end
    end
    private_class_method :resource_reader

    # Keeps bytes in the scratchpad of the agent that made the call, and
    # returns where. nil when that agent has none.
    def saver(context, local)
      ->(bytes, extension) { context&.scratchpad&.save_binary(bytes, local, extension) }
    end
    private_class_method :saver

    # A key that names no tool would leave the tool it was meant for to its
    # hint, which can mark a tool the host set to run alone.
    def known_marks!(parallel, listed)
      return unless parallel.is_a?(Hash)

      unknown = parallel.keys - listed.grep(Hash).map { |tool| tool["name"] }
      return if unknown.empty?

      names = unknown.map { |name| label(name) }.join(", ")
      raise ConfigurationError, "parallel: names no tool of this server: #{names}"
    end
    private_class_method :known_marks!

    def claim(taken, local, remote)
      holder = taken[local]
      if holder
        raise ConfigurationError,
              "MCP tool #{label(remote)}: the name #{local.inspect} is taken by #{label(holder)}"
      end

      taken[local] = remote
    end
    private_class_method :claim

    # Text every later step can take: a name is matched and compared, and
    # both travel to a provider as JSON.
    def utf8?(text)
      text.ascii_only? || (text.encoding == Encoding::UTF_8 && text.valid_encoding?)
    end
    private_class_method :utf8?

    # A remote name is the server's to choose, so a message carries its start.
    def label(remote) = remote.inspect[0, 120]
    private_class_method :label

    # The text a server's tools carry into the conversation: the host's own
    # string, the server's instructions, or none.
    def instructions_for(client, choice)
      return choice if choice.is_a?(String)

      client.instructions if choice && client.respond_to?(:instructions)
    end
    private_class_method :instructions_for

    # The model calls the tool by name, or by a safe name made from prefix and
    # the remote name. The server is always called with the remote name.
    def bridge(client, spec, prefix: nil, name: nil, gate: false,
               complete_argument_validator: nil, deferred: false, instructions: nil,
               parallel: nil, timeout: CALL_TIMEOUT, description_limit: DESCRIPTION_LIMIT,
               instructions_as: :system, trust_hints: true, reader: nil)
      raise ConfigurationError, "the definition is not an object" unless spec.is_a?(Hash)

      remote = spec["name"]
      unless remote.is_a?(String) && !remote.empty?
        raise ConfigurationError, "the definition has no name"
      end
      raise ConfigurationError, "the name is not valid UTF-8" unless utf8?(remote)

      description = spec["description"].to_s
      raise ConfigurationError, "the description is not valid UTF-8" unless utf8?(description)

      local = name || local_name(remote, prefix)
      if spec.key?("inputSchema") && spec["inputSchema"].nil?
        raise ConfigurationError, "inputSchema must be an object, not null"
      end

      raw_schema = spec.fetch("inputSchema", EMPTY_INPUT_SCHEMA)
      input_schema = Schema.validate_mcp!(
        raw_schema, complete: !complete_argument_validator.nil?
      )
      Tool.define(local, bounded(description, description_limit),
                  input_schema: input_schema, parallel: marked?(spec, parallel, trust_hints),
                  needs_approval: gate, deferred: deferred, instructions: instructions,
                  instructions_as: instructions_as, timeout: timeout,
                  complete_argument_validator: complete_argument_validator) do |args, context|
        shown(client.call_tool(remote, args || {}), reader, saver(context, local))
      rescue NotSent, AuthenticationError => e
        ToolResult.new(content: unreachable(local, prefix, e), error: true)
      end
    rescue ConfigurationError => e
      raise ConfigurationError, "MCP tool #{label(remote)}: #{e.message}"
    end

    # Without the host's choice a tool is marked by its readOnlyHint, which is
    # the server's own word about its tool. Nothing checks it, so a host that
    # does not trust the server turns the hint off.
    def marked?(spec, choice, trusted)
      return choice unless choice.nil?

      annotations = spec["annotations"]
      trusted && annotations.is_a?(Hash) && annotations["readOnlyHint"] == true
    end
    private_class_method :marked?

    # What the model reads when a tool could not run because its server could
    # not be used: which server, by the name the host gave it, and why.
    def unreachable(local, prefix, error)
      server = prefix ? "the MCP server #{prefix.to_s.inspect}" : "the MCP server"
      if error.is_a?(AuthenticationError)
        return "#{local} did not run: #{server} needs a sign-in before its tools can be used " \
               "(#{error.message})."
      end

      "No connection to #{server} could be established, so #{local} did not run: #{error.message}"
    end
    private_class_method :unreachable

    def bounded(description, limit)
      return description if limit.nil? || description.length <= limit

      "#{description[0, limit]}\n[cut at #{limit} of #{description.length} characters]"
    end
    private_class_method :bounded

    # The SHA-256 of a tool's definition, as JSON with the keys of every
    # object in order. A host keeps it with the definition a person approved.
    def digest(definition)
      Digest::SHA256.hexdigest(JSON.generate(ordered(JSON.parse(JSON.generate(definition)))))
    end

    # The names of the tools that a fresh listing adds, removes and changes,
    # against a kept one. Each is what Client#listing returned, or an array
    # of definitions.
    def changes(kept, fresh)
      before, after = [kept, fresh].map do |listing|
        tools = listing.is_a?(Hash) ? listing["tools"] : listing
        Array(tools).grep(Hash).to_h { |tool| [tool["name"], digest(tool)] }
      end
      { "added" => after.keys - before.keys, "removed" => before.keys - after.keys,
        "changed" => before.keys.select { |name| after.key?(name) && after[name] != before[name] } }
    end

    def ordered(value)
      case value
      when Hash then value.sort.to_h.transform_values { |member| ordered(member) }
      when Array then value.map { |member| ordered(member) }
      else value
      end
    end
    private_class_method :ordered

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
    # A link to a resource and bytes that are neither an image nor text are
    # named and nothing more: a bridged tool does more with them.
    def answer(result) = shown(result, nil, nil)

    # reader is the name of the tool that reads this server's resources, and
    # save a callable that keeps bytes and returns where. With them a link
    # names that tool, and bytes a model cannot read are kept for it.
    def shown(result, reader, save)
      blocks = Array(result["content"]).map { |block| convert(block, reader, save) }
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
    private_class_method :shown

    def convert(block, reader = nil, save = nil)
      case block["type"]
      when "text" then block["text"].to_s
      when "image"
        Content::Image.new(data: block["data"], mime_type: block["mimeType"] || "image/png")
      when "resource" then embedded(block["resource"] || {}, save)
      when "resource_link" then link(block, reader)
      else "[unsupported #{block["type"]} content]"
      end
    end

    # A resource a server put into a result: its text, or its bytes. Bytes
    # that are an image are shown, bytes of a text type are read as text, and
    # any other bytes are kept where the agent can find them.
    def embedded(resource, save)
      return resource["text"] if resource["text"]

      blob = resource["blob"]
      return "[resource: #{resource["uri"]}]" unless blob.is_a?(String)

      type = resource["mimeType"].to_s
      return Content::Image.new(data: blob, mime_type: type) if type.start_with?("image/")

      bytes = Content.strict_base64(blob).unpack1("m0")
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return text if TEXT_TYPE.match?(type) && text.valid_encoding?

      kept(resource["uri"], type, bytes, save)
    end
    private_class_method :embedded

    def kept(uri, type, bytes, save)
      return "[resource: #{uri}]" unless save

      about = "#{uri} (#{type.empty? ? "unknown type" : type}, #{bytes.bytesize} bytes)"
      path = save.call(bytes, uri.to_s[/\.[A-Za-z0-9]{1,8}\z/] || ".bin")
      return "[Binary resource #{about} saved at #{path}]" if path

      "[Binary resource #{about} is not shown: the agent has no scratchpad to keep it in]"
    rescue StandardError => e
      "[Binary resource #{about} could not be saved: #{e.message}]"
    end
    private_class_method :kept

    def link(block, reader)
      return "[resource: #{block["uri"]}]" unless reader

      label = [block["title"], block["name"]].grep(String).first
      details = [block["mimeType"], (size = block["size"]) && "#{size} bytes"].compact.join(", ")
      named = "Resource #{block["uri"]}"
      named += " #{label.inspect}" if label
      named += " (#{details})" unless details.empty?
      about = block["description"].strip.delete_suffix(".") if block["description"].is_a?(String)
      "[#{[named, about, "Read it with #{reader}"].compact.join(". ")}.]"
    end
    private_class_method :link
  end
end

require_relative "mcp/egress"
require_relative "mcp/mirror"
require_relative "mcp/negotiation"
require_relative "mcp/conversation"
require_relative "mcp/wires"
require_relative "mcp/client"
require_relative "mcp/oauth"

Mistri::MCP.private_constant :Egress, :Mirror, :WireError, :WireTimeout, :EMPTY_INPUT_SCHEMA,
                             :READ_RESOURCE, :READ_RESOURCE_SCHEMA, :TEXT_TYPE,
                             :NAME_LIMIT, :SAFE_NAME
