# frozen_string_literal: true

module Mistri
  module MCP
    # The 2026-07-28 revision repeats parts of a request in HTTP headers, so
    # that a gateway can route a call without reading its body. A server marks
    # a tool parameter for this with "x-mcp-header" in the parameter's schema,
    # and the value of the mark names the header: Mcp-Param-{name}.
    module Mirror
      MARK = "x-mcp-header"
      TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
      PRIMITIVES = %w[integer string boolean].freeze
      # What a header value holds as it is: visible ASCII, with spaces inside.
      PLAIN = /\A(?:[\x21-\x7E](?:[\x20-\x7E]*[\x21-\x7E])?)?\z/n
      ENCODED = /\A=\?base64\?.*\?=\z/mn

      module_function

      # Why the marks of a tool cannot be honoured, or nil. The revision has a
      # client leave such a tool out of the list.
      def violation(schema)
        marked = marks(schema)
        names = marked.map { |_path, property| property[MARK] }
        if total(schema) != marked.length
          "#{MARK} is on a parameter that property names alone do not reach"
        elsif !names.all? { |name| name.is_a?(String) && TOKEN.match?(name) }
          "#{MARK} is not a header name"
        elsif names.map(&:downcase).uniq.length != names.length
          "#{MARK} names one header twice"
        elsif !marked.all? { |_path, property| PRIMITIVES.include?(property["type"]) }
          "#{MARK} is on a parameter that is not a string, an integer or a boolean"
        end
      end

      # The headers of one call: a header for each marked parameter the
      # arguments hold. A parameter that is absent or null gets none.
      def headers(schema, arguments)
        marked = marks(schema)
        return {} if marked.empty?

        given = JSON.parse(JSON.generate(arguments || {}))
        marked.each_with_object({}) do |(path, property), headers|
          found = path.reduce(given) { |node, name| node.is_a?(Hash) ? node[name] : nil }
          next unless found.is_a?(String) || found.is_a?(Integer) || [true, false].include?(found)

          headers["Mcp-Param-#{property[MARK]}"] = value(found.to_s)
        end
      end

      # A value as a header carries it: as it is when plain, and as base64
      # when it is not, or when it would be taken for the base64 form.
      def value(text)
        raw = text.b
        return text if PLAIN.match?(raw) && !ENCODED.match?(raw)

        "=?base64?#{[text].pack("m0")}?="
      end

      # The marked parameters that a chain of property names reaches, each
      # with its path.
      def marks(schema, path = [], found = [])
        properties = schema["properties"] if schema.is_a?(Hash)
        return found unless properties.is_a?(Hash)

        properties.each do |name, property|
          next unless property.is_a?(Hash)

          found << [[*path, name], property] if property.key?(MARK)
          marks(property, [*path, name], found)
        end
        found
      end

      # Every mark in the schema, wherever it is. The keys of "properties" are
      # the names of parameters, and no keywords.
      def total(node, names: false)
        case node
        when Array then node.sum { |item| total(item) }
        when Hash
          node.sum do |key, value|
            (!names && key == MARK ? 1 : 0) + total(value, names: !names && key == "properties")
          end
        else 0
        end
      end
    end
  end
end
