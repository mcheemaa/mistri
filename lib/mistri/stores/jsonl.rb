# frozen_string_literal: true

require "json"
require "fileutils"

module Mistri
  module Stores
    # One JSONL file per session under a directory: durable sessions without
    # a database, and a transcript any tool can read line by line.
    class JSONL
      SAFE_ID = /\A[A-Za-z0-9_-]{1,64}\z/
      private_constant :SAFE_ID

      def initialize(dir)
        @dir = dir
        FileUtils.mkdir_p(dir)
      end

      # One write call per line: concurrent appenders (a steer, a child's
      # report) interleave whole lines, never fragments. A fragment left by a
      # crash mid-write gets its own newline so it never swallows this entry.
      def append(id, entry)
        File.open(path(id), "a+", 0o600) do |file|
          line = "#{JSON.generate(entry)}\n"
          line = "\n#{line}" if file.size.positive? && file.pread(1, file.size - 1) != "\n"
          file.write(line)
        end
        nil
      end

      def load(id)
        return [] unless File.exist?(path(id))

        File.readlines(path(id)).filter_map do |line|
          JSON.parse(line) unless line.strip.empty?
        rescue JSON::ParserError
          nil
        end
      end

      private

      # Session ids become filenames. Rewriting a hostile id would alias two
      # sessions onto one file, so it is rejected instead.
      def path(id)
        unless SAFE_ID.match?(id.to_s)
          raise ArgumentError, "session id #{id.inspect} is not a safe filename"
        end

        File.join(@dir, "#{id}.jsonl")
      end
    end
  end
end
