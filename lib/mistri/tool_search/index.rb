# frozen_string_literal: true

module Mistri
  module ToolSearch
    # The text index behind tool_search: one document for each tool, built
    # from its name, its description and its parameters, and ranked with
    # Okapi BM25.
    module Index
      # Okapi BM25 over the description and the parameters.
      K1 = 1.2
      B = 0.75
      # A query word in the name outweighs any number of mentions in the text,
      # whose share is at most K1 + 1.
      NAME_WEIGHT = 3
      STOP_WORDS = %w[
        a an and are as at be by for from in is it of on or that the this to with
      ].freeze
      # Han, kana and Hangul letters, and the long vowel mark that sits inside
      # kana words. Runs of these often have no spaces between words.
      UNSPACED = "\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}\\u30FC"
      WORD = /[#{UNSPACED}]+|[[:alnum:]&&[^#{UNSPACED}]]+/
      UNSPACED_RUN = /\A[#{UNSPACED}]/
      UNSPACED_PAIR = /[#{UNSPACED}]{2,}/
      private_constant :K1, :B, :NAME_WEIGHT, :STOP_WORDS, :UNSPACED, :WORD, :UNSPACED_RUN,
                       :UNSPACED_PAIR

      Document = Data.define(:tool, :size, :alike, :name_words, :local_words, :counts, :length)
      private_constant :Document

      module_function

      # The matches for a query, best first.
      def search(query, documents)
        terms = words(query).uniq
        weights = weights(terms, documents)
        average = documents.sum(&:length).fdiv(documents.length).nonzero? || 1.0
        text = query.strip
        wanted = identifier(text)
        matches = documents.each_with_index.filter_map do |document, index|
          name = name_rank(document, text, wanted)
          covered, score = score(document, terms, weights, average)
          [name, -covered, -score, index, document] if covered.positive? || name < 3
        end
        matches.sort.map(&:last)
      end

      # How a query names a tool: 0 its name, 1 its name without the prefix,
      # 2 a name that reads the same, 3 not at all.
      def name_rank(document, query, wanted)
        name = document.tool.name
        return 3 if query.empty?
        return 0 if name == query
        return 1 if name.end_with?("__#{query}")

        alike = wanted && document.alike
        alike && (alike == wanted || alike.end_with?("__#{wanted}")) ? 2 : 3
      end

      # One document for each tool.
      def documents(tools) = tools.map { |tool| document(tool) }

      def document(tool)
        spec = tool.spec.transform_keys(&:to_sym)
        parts = [spec[:description].to_s]
        schema_text(spec[:input_schema], parts)
        text = plain(parts.join(" "))
        terms = words(text)
        Document.new(tool:, size: JSON.generate(spec).bytesize, alike: identifier(tool.name),
                     name_words: (words(tool.name) + characters(plain(tool.name))).uniq,
                     local_words: words(tool.name.split("__").last).uniq,
                     counts: (terms + characters(text)).tally, length: terms.length)
      end
      private_class_method :document

      # The single characters of the runs that are matched by pairs, so that a
      # query of one character finds them. They are extra entries: a text's
      # length is counted without them.
      def characters(text) = text.scan(UNSPACED_PAIR).flat_map(&:chars)
      private_class_method :characters

      # Text in one width and one composed form, so that half-width kana and a
      # letter written as two marks match their usual form.
      def plain(text)
        text = text.to_s
        text.ascii_only? ? text : text.unicode_normalize(:nfkc)
      end
      private_class_method :plain

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
        plain(text).gsub(/([a-z0-9])([A-Z])/, '\1 \2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1 \2')
                   .downcase.scan(WORD)
                   .flat_map { |word| word.match?(UNSPACED_RUN) ? pairs(word) : word }
                   .reject { |word| STOP_WORDS.include?(word) }.map { |word| singular(word) }
      end

      # A run with no spaces has no words to split at, so it is matched by its
      # pairs of characters, and a run of one character is itself.
      def pairs(run)
        run.length < 2 ? [run] : run.each_char.each_cons(2).map(&:join)
      end
      private_class_method :pairs

      def singular(word)
        return "#{word[0...-3]}y" if word.length > 4 && word.end_with?("ies")
        return word[0...-2] if word.length > 4 && word.match?(/(?:ch|sh|ss|x|z)es\z/)
        return word[0...-1] if word.length > 3 && word.end_with?("s") && !word.end_with?("ss")

        word
      end
      private_class_method :singular

      # A name as it reads whatever its case and punctuation, or nil for text
      # that could not be a name at all.
      def identifier(text)
        text.downcase.gsub(/[-. ]/, "_") if text.match?(/\A[\w\-. ]*[A-Za-z0-9][\w\-. ]*\z/)
      end
    end
  end
end
