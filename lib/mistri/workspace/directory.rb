# frozen_string_literal: true

require "fileutils"
require_relative "../workspace"

module Mistri
  module Workspace
    # Documents as ordinary files under a host-controlled root. Model-supplied
    # paths cannot escape lexically or traverse an existing symlink. The host
    # must keep the root and tree stable for the instance's lifetime; this is
    # not an OS sandbox against concurrent filesystem mutation.
    class Directory
      def initialize(root)
        expanded = File.expand_path(root)
        FileUtils.mkdir_p(expanded)
        @root = File.realpath(expanded)
        @root_prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
      end

      def read(path)
        full = resolve(path)
        File.exist?(full) ? File.read(full) : nil
      end

      def write(path, content)
        full = resolve(path)
        FileUtils.mkdir_p(File.dirname(full))
        full = resolve(path)
        File.write(full, content.to_s)
        nil
      end

      def delete(path)
        full = resolve(path)
        FileUtils.rm_f(full)
        nil
      end

      def list(prefix = nil)
        paths = Dir.glob("**/*", base: @root).filter_map do |path|
          full = File.join(@root, path)
          next if traverses_symlink?(full)
          next unless File.file?(full)

          path
        end.sort
        prefix ? paths.select { |p| p.start_with?(prefix.to_s) } : paths
      end

      private

      def resolve(path)
        full = File.expand_path(path.to_s, @root)
        unless full == @root || full.start_with?(@root_prefix)
          raise SchemaError, "path escapes the workspace: #{path}"
        end
        raise SchemaError, "path traverses a symlink: #{path}" if traverses_symlink?(full)

        full
      end

      def traverses_symlink?(full)
        current = @root
        relative = full.delete_prefix(@root).delete_prefix(File::SEPARATOR)
        relative.split(File::SEPARATOR).any? do |part|
          current = File.join(current, part)
          File.symlink?(current)
        end
      end
    end
  end
end
