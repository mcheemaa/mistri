# frozen_string_literal: true

require "fileutils"

module Mistri
  module Workspace
    # Documents as files under one root. Every path resolves inside the root
    # or raises, so a model-supplied "../../etc/passwd" cannot escape.
    class Directory
      def initialize(root)
        @root = File.expand_path(root)
        FileUtils.mkdir_p(@root)
      end

      def read(path)
        full = resolve(path)
        File.exist?(full) ? File.read(full) : nil
      end

      def write(path, content)
        full = resolve(path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content.to_s)
        nil
      end

      def delete(path)
        full = resolve(path)
        FileUtils.rm_f(full)
        nil
      end

      def list(prefix = nil)
        base = @root.length + 1
        paths = Dir.glob(File.join(@root, "**", "*")).select { |f| File.file?(f) }
                                                     .map { |f| f[base..] }.sort
        prefix ? paths.select { |p| p.start_with?(prefix.to_s) } : paths
      end

      private

      def resolve(path)
        full = File.expand_path(path.to_s, @root)
        unless full == @root || full.start_with?("#{@root}#{File::SEPARATOR}")
          raise SchemaError, "path escapes the workspace: #{path}"
        end

        full
      end
    end
  end
end
