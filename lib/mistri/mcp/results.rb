# frozen_string_literal: true

module Mistri
  # What the result of an MCP call becomes for a model. Part of the bridge.
  module MCP
    module_function

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
