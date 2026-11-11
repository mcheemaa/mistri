# frozen_string_literal: true

module Mistri
  # Finds the tools an agent has not shown the model yet. A deferred tool
  # costs no tokens until a search loads it: the model asks in words, the
  # best matches are loaded, and it can call them from its next step.
  module ToolSearch
    NAME = "tool_search"
    LIMIT = 8
    MAX_LIMIT = 20
    # Okapi BM25 over the description and the parameters.
    K1 = 1.2
    B = 0.75
    # A query word in the name outweighs any number of mentions in the text,
    # whose share is at most K1 + 1.
    NAME_WEIGHT = 3
    STOP_WORDS = %w[
      a an and are as at be by for from in is it of on or that the this to with
    ].freeze
    private_constant :K1, :B, :NAME_WEIGHT, :STOP_WORDS

    Document = Data.define(:tool, :summary, :name_words, :local_words, :counts, :length)
    private_constant :Document

    module_function

    # The tool an agent adds when it holds deferred tools.
    def tool(deferred)
      documents = nil
      Tool.define(NAME, description(deferred), schema: lambda {
        string :query, "Words for what you need to do", required: true
        integer :limit, "How many tools to load at most (default #{LIMIT}, at most #{MAX_LIMIT})"
      }) do |args|
        query = args["query"].to_s
        next ToolResult.new(content: "The query is empty. Say what you need to do.", error: true) \
          if words(query).empty?

        documents ||= deferred.map { |tool| document(tool) }
        answer(search(query, documents, args.fetch("limit", LIMIT).to_i.clamp(1, MAX_LIMIT)))
      end
    end

    # The best matches, best first. A tool that matches more of the query's
    # words comes before one that matches fewer, whatever their scores, and a
    # query that is a tool's name, with or without its prefix, finds it first.
    # Equal matches keep the order the tools were given in.
    def rank(query, tools, limit)
      search(query, tools.map { |tool| document(tool) }, limit).map(&:tool)
    end

    def search(query, documents, limit)
      terms = words(query).uniq
      return [] if terms.empty? || limit <= 0

      weights = weights(terms, documents)
      average = documents.sum(&:length).fdiv(documents.length).nonzero? || 1.0
      exact = identifier(query)
      matches = documents.each_with_index.filter_map do |document, index|
        covered, score = score(document, terms, weights, average)
        next if covered.zero?

        named = identifier(document.tool.name)
        [named == exact || named.end_with?("__#{exact}") ? 0 : 1, -covered, -score, index, document]
      end
      matches.sort.first(limit).map(&:last)
    end
    private_class_method :search

    def description(deferred)
      "Finds tools that are not loaded yet and loads the best matches. You can call a loaded " \
        "tool from your next step. Search here before you say you cannot do something.\n" \
        "Not loaded yet: #{waiting(deferred)}."
    end
    private_class_method :description

    def waiting(deferred)
      prefixed, plain = deferred.map(&:name).partition { |name| name.include?("__") }
      groups = prefixed.group_by { |name| name.split("__", 2).first }.map do |prefix, names|
        "#{prefix} (#{count(names.length, "tool")})"
      end
      groups << count(plain.length, groups.empty? ? "tool" : "other") if plain.any?
      groups.join(", ")
    end
    private_class_method :waiting

    def count(number, noun) = "#{number} #{noun}#{"s" unless number == 1}"
    private_class_method :count

    def answer(found)
      return "No tool matches. Try other words." if found.empty?

      lines = found.map { |document| "- #{document.tool.name}: #{document.summary}" }
      ToolResult.new(
        content: "Loaded #{count(found.length, "tool")}. You can call them from your next " \
                 "step:\n#{lines.join("\n")}",
        loads: found.map { |document| document.tool.name }
      )
    end
    private_class_method :answer

    def document(tool)
      spec = tool.spec.transform_keys(&:to_sym)
      description = spec[:description].to_s
      parts = [description]
      schema_text(spec[:input_schema], parts)
      counts = words(parts.join(" ")).tally
      Document.new(tool:, summary: description.lines.first.to_s.strip,
                   name_words: words(tool.name).uniq,
                   local_words: words(tool.name.split("__").last).uniq,
                   counts:, length: counts.sum { |_word, times| times })
    end
    private_class_method :document

    # Descriptions and property names, through nested objects, arrays,
    # alternatives and shared definitions.
    def schema_text(schema, parts)
      return unless schema.is_a?(Hash)

      description = keyword(schema, "description")
      parts << description if description.is_a?(String)
      named(schema, "properties").each do |name, property|
        parts << name.to_s
        schema_text(property, parts)
      end
      schema_text(keyword(schema, "items"), parts)
      %w[anyOf oneOf allOf].each do |alternatives|
        Array(keyword(schema, alternatives)).each { |member| schema_text(member, parts) }
      end
      %w[$defs definitions].each do |shared|
        named(schema, shared).each_value { |member| schema_text(member, parts) }
      end
    end
    private_class_method :schema_text

    def keyword(schema, name) = schema[name] || schema[name.to_sym]
    private_class_method :keyword

    def named(schema, name)
      members = keyword(schema, name)
      members.is_a?(Hash) ? members : {}
    end
    private_class_method :named

    # How rare each query word is across the tools.
    def weights(terms, documents)
      terms.to_h do |term|
        holders = documents.count do |document|
          document.name_words.include?(term) || document.counts.key?(term)
        end
        [term, Math.log(1 + ((documents.length - holders + 0.5) / (holders + 0.5)))]
      end
    end
    private_class_method :weights

    def score(document, terms, weights, average)
      norm = K1 * (1 - B + (B * document.length / average))
      covered = 0
      score = terms.sum do |term|
        times = document.counts.fetch(term, 0)
        weight = (document.name_words.include?(term) ? NAME_WEIGHT : 0) +
                 (times * (K1 + 1) / (times + norm))
        covered += 1 if weight.positive?
        weights.fetch(term) * weight
      end
      whole_name = document.local_words.any? && (document.local_words - terms).empty?
      [covered, whole_name ? score + weights.sum { |_term, weight| weight } : score]
    end
    private_class_method :score

    def words(text)
      text.to_s.gsub(/([a-z0-9])([A-Z])/, '\1 \2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1 \2')
          .downcase.scan(/[[:alnum:]]+/)
          .reject { |word| STOP_WORDS.include?(word) }.map { |word| singular(word) }
    end
    private_class_method :words

    def singular(word)
      return "#{word[0...-3]}y" if word.length > 4 && word.end_with?("ies")
      return word[0...-2] if word.length > 4 && word.match?(/(?:ch|sh|ss|x|z)es\z/)
      return word[0...-1] if word.length > 3 && word.end_with?("s") && !word.end_with?("ss")

      word
    end
    private_class_method :singular

    def identifier(text) = text.to_s.strip.downcase.gsub(/[^a-z0-9_]/, "_")
    private_class_method :identifier
  end
end
