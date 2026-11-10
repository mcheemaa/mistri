# frozen_string_literal: true

require "json"
require "fileutils"

module Mistri
  module Stores
    # One JSONL file per session under a directory: durable sessions without
    # a database, and a transcript any tool can read line by line.
    class JSONL
      # 249 characters and the extension fill a 255-byte filename.
      SAFE_ID = /\A[A-Za-z0-9_-]{1,249}\z/
      private_constant :SAFE_ID

      def initialize(dir)
        @dir = dir
        FileUtils.mkdir_p(dir)
      end

      # One write call per line: concurrent appenders (a steer, a child's
      # report) interleave whole lines, never fragments. A crash's partial last
      # line gets a newline first so it cannot swallow this entry.
      def append(id, entry)
        File.open(path(id), "a+", 0o600) do |file|
          line = "#{JSON.generate(entry)}\n"
          line = "\n#{line}" if file.size.positive? && file.pread(1, file.size - 1) != "\n"
          file.write(line)
        end
        nil
      end

      # A partial line from a crash mid-write must not block every later load.
      # It is not an entry, so every line is parsed to count the ones before from.
      def load(id, from: 0)
        return [] unless File.exist?(path(id))

        entries = File.readlines(path(id)).filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        entries.drop(from)
      end

      def settled? = true

      private

      # Session ids become filenames; a sanitized id would alias two sessions
      # onto one file.
      def path(id)
        raise ArgumentError, "unsafe session id #{id.inspect}" unless SAFE_ID.match?(id.to_s)

        File.join(@dir, "#{id}.jsonl")
      end
    end
  end
end
