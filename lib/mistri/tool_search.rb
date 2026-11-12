# frozen_string_literal: true

require_relative "tool_search/index"

module Mistri
  # Finds the tools an agent has not shown the model yet. A deferred tool
  # costs no tokens until a search loads it: the model asks in words, the
  # best matches are loaded, and it can call them from its next step.
  module ToolSearch
    NAME = "tool_search"
    DESCRIPTION = "Finds tools you have not been shown and loads the best matches. You can " \
                  "call a loaded tool from your next step. Search here before you say you " \
                  "cannot do something."
    LIMIT = 5
    MAX_LIMIT = 20
    # The definitions of one load, in bytes. Of 303 measured MCP definitions,
    # nine in ten were under 2,200.
    LOAD_BYTES = 20_000
    # The names in one listing, in bytes. The 303 measured MCP names average
    # 25 bytes, so about 800 names fit.
    LISTING_BYTES = 20_000
    QUERY_LIMIT = 500
    # The list names every deferred tool, the loaded ones too.
    LOADED = "Once a #{NAME} result states that a tool is loaded, call it directly and do not " \
             "load it again.".freeze
    SELECT = /\Aselect:/i
    private_constant :DESCRIPTION, :LOADED, :SELECT, :Index

    module_function

    # The tool an agent adds when it holds deferred tools. loaded returns
    # the names of the tools already loaded. A search does not load those
    # again: its result states that they are loaded and names them in loads,
    # so they stay loaded while that result is in the history. A search
    # appends the names it loads to the list, so two searches in one turn do
    # not load the same tool.
    def tool(deferred, loaded: -> { [] })
      documents = nil
      turn = Mutex.new
      Tool.define(NAME, DESCRIPTION, schema: lambda {
        string :query, "Words that describe what you need to do, or select: followed by " \
                       "the exact names of the tools to load, separated by commas",
               required: true
        integer :limit, "How many tools to load at most (default #{LIMIT}, at most #{MAX_LIMIT})"
      }) do |args|
        query = args["query"].to_s[0, QUERY_LIMIT]
        documents ||= Index.documents(deferred)
        chosen, missing, requested = named_tools(query, documents)
        unless chosen || Index.words(query).any?
          next ToolResult.new(content: "The query has no words to search for. Describe what " \
                                       "you need to do in a few words.", error: true)
        end

        limit = args.fetch("limit") { [LIMIT, requested.to_i].max }.to_i.clamp(1, MAX_LIMIT)
        matches = chosen || Index.search(query, documents)
        names = loaded.call
        fresh, held, left = turn.synchronize do
          unloaded(matches, names, limit).tap do |picked, _|
            names.concat(picked.map { |document| document.tool.name })
          end
        end
        answer(fresh, held, missing.to_a, left, named: !chosen.nil?, full: fresh.length == limit)
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

      Index.search(query, Index.documents(tools)).first(limit).map(&:tool)
    end

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
        wanted = Index.identifier(part)
        ranks = documents.group_by { |document| Index.name_rank(document, part, wanted) }
        closest = ranks.keys.min
        closest && closest <= yield(part) ? found.concat(ranks.fetch(closest)) : missing << part
      end
      [found.uniq, missing]
    end
    private_class_method :pick

    # The matches to load, the loaded matches ranked before them, and the
    # number of matches left unloaded. A load holds up to limit tools and up
    # to LOAD_BYTES of definitions, and always its first tool.
    def unloaded(matches, loaded, limit)
      have = loaded.to_set
      fresh = []
      held = []
      left = 0
      room = LOAD_BYTES
      matches.each do |document|
        open = left.zero? && fresh.length < limit
        if have.include?(document.tool.name)
          held << document if open
        elsif open && (fresh.empty? || document.size <= room)
          fresh << document
          room -= document.size
        else
          left += 1
        end
      end
      [fresh, held, left]
    end
    private_class_method :unloaded

    # The listing the model reads: every deferred name, or the number of
    # tools under each prefix once the names exceed LISTING_BYTES.
    def listing(names)
      return "No tools load on demand now. This list replaces any earlier one." if names.empty?

      if names.sum(&:bytesize) > LISTING_BYTES
        return "These tools load on demand. There are too many to list by name: " \
               "#{inventory(names)}. Load one with #{NAME} before you call it: search with " \
               "words that describe what you need. #{LOADED} This list replaces any earlier one."
      end

      "These tools load on demand. Load one with #{NAME} before you call it: search with " \
        "words that describe what you need, or use select: followed by the names. #{LOADED} " \
        "This list replaces any earlier one.\n#{names.join("\n")}"
    end

    # The number of tools under each prefix, up to LISTING_BYTES of prefixes.
    # Tools without a prefix and tools under the remaining prefixes are
    # counted together.
    def inventory(names)
      groups = names.select { |name| name.include?("__") }
                    .group_by { |name| name.split("__", 2).first }
      room = LISTING_BYTES
      listed = groups.map { |prefix, group| "#{prefix} (#{count(group.length, "tool")})" }
                     .take_while { |entry| (room -= entry.bytesize + 2) >= 0 }
      others = names.length - groups.values.first(listed.length).sum(&:length)
      listed << count(others, listed.empty? ? "tool" : "other") if others.positive?
      listed.join(", ")
    end
    private_class_method :inventory

    def count(number, noun) = "#{number} #{noun}#{"s" unless number == 1}"
    private_class_method :count

    # named: the query named tools, so the result gives the number left
    # unloaded. full: the load reached its count, so a word search adds no
    # line about further matches.
    def answer(fresh, held, missing, left, named:, full:)
      lines = []
      lines << "Loaded: #{names(fresh)}. You can call them from your next step." if fresh.any?
      lines << "Already loaded, call them directly: #{names(held)}." if held.any?
      if left.positive? && named
        lines << "#{count(left, "more tool")} with these names. Search again to load them."
      elsif left.positive? && !full
        lines << "More tools match than one load holds. Search again to load them."
      end
      lines << "No tool is named #{missing.join(", ")}." if missing.any?
      return "No tool matches. Try other words." if lines.empty?

      ToolResult.new(content: lines.join("\n"),
                     loads: (fresh + held).map { |document| document.tool.name })
    end
    private_class_method :answer

    def names(documents)
      listed = documents.first(MAX_LIMIT).map { |document| document.tool.name }.join(", ")
      documents.length > MAX_LIMIT ? "#{listed} and #{documents.length - MAX_LIMIT} more" : listed
    end
    private_class_method :names
  end
end
