# frozen_string_literal: true

require "json"
require "fileutils"

module Mistri
  module Stores
    # One JSONL file per session under a directory: durable sessions without
    # a database, and a transcript any tool can read line by line.
    class JSONL
      def initialize(dir)
        @dir = dir
        FileUtils.mkdir_p(dir)
      end

      def append(id, entry)
        File.open(path(id), "a") { |file| file.puts(JSON.generate(entry)) }
        nil
      end

      def load(id)
        return [] unless File.exist?(path(id))

        File.readlines(path(id)).filter_map do |line|
          JSON.parse(line) unless line.strip.empty?
        end
      end

      private

      # Session ids become filenames; anything path-hostile is replaced.
      def path(id)
        File.join(@dir, "#{id.to_s.gsub(/[^a-zA-Z0-9_-]/, "-")}.jsonl")
      end
    end
  end
end
