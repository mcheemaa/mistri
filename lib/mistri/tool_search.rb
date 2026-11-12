# frozen_string_literal: true

module Mistri
  # Finds the tools an agent has not shown the model yet. A deferred tool
  # costs no tokens until a search loads it: the model asks in words, the
  # best matches are loaded, and it can call them from its next step.
  module ToolSearch
    NAME = "tool_search"
    LIMIT = 8
    MAX_LIMIT = 20
    QUERY_LIMIT = 500
    SELECT = /\Aselect:/i
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
    private_constant :SELECT, :K1, :B, :NAME_WEIGHT, :STOP_WORDS, :UNSPACED, :WORD,
                     :UNSPACED_RUN, :UNSPACED_PAIR

    Document = Data.define(:tool, :alike, :name_words, :local_words, :counts, :length)
    private_constant :Document

    module_function

    # The tool an agent adds when it holds deferred tools. loaded returns
    # the names of the tools already loaded, which a search skips. A search
    # appends the names it loads to that list, so two searches in one turn
    # do not load the same tool.
    def tool(deferred, loaded: -> { [] })
      documents = nil
      turn = Mutex.new
      Tool.define(NAME, description(deferred), schema: lambda {
        string :query, "Words that describe what you need to do, or select: followed by " \
                       "the exact names of the tools to load, separated by commas",
               required: true
        integer :limit, "How many tools to load at most (default #{LIMIT}, at most #{MAX_LIMIT})"
      }) do |args|
        query = args["query"].to_s[0, QUERY_LIMIT]
        documents ||= deferred.map { |tool| document(tool) }
        chosen, missing, requested = named_tools(query, documents)
        unless chosen || words(query).any?
          next ToolResult.new(content: "The query has no words to search for. Describe what " \
                                       "you need to do in a few words.", error: true)
        end

        limit = args.fetch("limit") { [LIMIT, requested.to_i].max }.to_i.clamp(1, MAX_LIMIT)
        matches = chosen || search(query, documents)
        names = loaded.call
        fresh, held, left = turn.synchronize do
          unloaded(matches, names, limit).tap do |picked, _|
            names.concat(picked.map { |document| document.tool.name })
          end
        end
        answer(fresh, held, missing.to_a, chosen ? left : 0)
      end
    end

    # The best matches, best first. A query that is a tool's name finds that
    # tool first: the name itself, then the name without its prefix, then a
    # name that reads the same with other punctuation. After those, a tool
    # that matches more of the query's words comes before one that matches
    # fewer, whatever their scores. Equal matches keep the order the tools
    # were given in.
    def rank(query, tools, limit)
      return [] if limit <= 0

      search(query, tools.map { |tool| document(tool) }).first(limit).map(&:tool)
    end

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
    private_class_method :search

    # The tools a query names, the names in it that match no tool, and the
    # number of names. Nil when the query is a word search. A query that
    # starts with select: is a list of names. A query that matches one tool's
    # name selects that tool. So does a list whose every part is a full name
    # or contains an underscore, when at least one part matches a tool: read
    # file is two words, never the tools x__read and y__file.
    def named_tools(query, documents)
      text = query.strip
      if text.match?(SELECT)
        parts = text.sub(SELECT, "").split(",")
        return [*pick(parts, documents) { 2 }, parts.length]
      end

      whole = pick([text], documents) { 2 }
      return [*whole, 1] if whole.first.any?

      parts = text.split(/[\s,]+/)
      found, missing = pick(parts, documents) { |part| part.include?("_") ? 2 : 0 }
      return unless parts.length > 1 && found.any? && missing.all? { |part| part.include?("_") }

      [found, missing, parts.length]
    end
    private_class_method :named_tools

    # For each part, the tools at its closest matching rank, up to the rank
    # the block allows for that part.
    def pick(parts, documents)
      found = []
      missing = []
      parts.map(&:strip).reject(&:empty?).each do |part|
        wanted = identifier(part)
        ranks = documents.group_by { |document| name_rank(document, part, wanted) }
        closest = ranks.keys.min
        closest && closest <= yield(part) ? found.concat(ranks.fetch(closest)) : missing << part
      end
      [found.uniq, missing]
    end
    private_class_method :pick

    # The matches to load, up to limit, the loaded matches ranked before
    # them, and the number of matches left unloaded.
    def unloaded(matches, loaded, limit)
      have = loaded.to_set
      fresh = []
      held = []
      left = 0
      matches.each do |document|
        if have.include?(document.tool.name)
          held << document if fresh.length < limit
        elsif fresh.length < limit
          fresh << document
        else
          left += 1
        end
      end
      [fresh, held, left]
    end
    private_class_method :unloaded

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
    private_class_method :name_rank

    def description(deferred)
      "Finds tools you have not been shown and loads the best matches. You can call a loaded " \
        "tool from your next step. Search here before you say you cannot do something.\n" \
        "It searches: #{inventory(deferred)}."
    end
    private_class_method :description

    def inventory(deferred)
      prefixed, plain = deferred.map(&:name).partition { |name| name.include?("__") }
      groups = prefixed.group_by { |name| name.split("__", 2).first }.map do |prefix, names|
        "#{prefix} (#{count(names.length, "tool")})"
      end
      groups << count(plain.length, groups.empty? ? "tool" : "other") if plain.any?
      groups.join(", ")
    end
    private_class_method :inventory

    def count(number, noun) = "#{number} #{noun}#{"s" unless number == 1}"
    private_class_method :count

    def answer(fresh, held, missing, left)
      lines = []
      lines << "Loaded: #{names(fresh)}. You can call them from your next step." if fresh.any?
      lines << "Already loaded, call them directly: #{names(held)}." if held.any?
      if left.positive?
        lines << "#{count(left, "more tool")} with these names. Search again to load them."
      end
      lines << "No tool is named #{missing.join(", ")}." if missing.any?
      return "No tool matches. Try other words." if lines.empty?

      ToolResult.new(content: lines.join("\n"), loads: fresh.map { |document| document.tool.name })
    end
    private_class_method :answer

    def names(documents)
      listed = documents.first(MAX_LIMIT).map { |document| document.tool.name }.join(", ")
      documents.length > MAX_LIMIT ? "#{listed} and #{documents.length - MAX_LIMIT} more" : listed
    end
    private_class_method :names

    def document(tool)
      spec = tool.spec.transform_keys(&:to_sym)
      parts = [spec[:description].to_s]
      schema_text(spec[:input_schema], parts)
      text = plain(parts.join(" "))
      terms = words(text)
      Document.new(tool:, alike: identifier(tool.name),
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
    private_class_method :words

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
    private_class_method :identifier
  end
end
