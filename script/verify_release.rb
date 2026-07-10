# frozen_string_literal: true

require "date"
require "open3"
require "rubygems"
require_relative "../lib/mistri/version"

module Mistri
  # ReleaseVerifier verifies that a publishable checkout is the declared release on main.
  class ReleaseVerifier
    class Error < StandardError; end

    STABLE_VERSION = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/

    def initialize(root:, tag:, main_ref:, event_name:, ref_type:, version: VERSION)
      @root = File.expand_path(root)
      @tag = tag.to_s
      @main_ref = main_ref.to_s
      @event_name = event_name.to_s
      @ref_type = ref_type.to_s
      @version = version.to_s
    end

    def verify!
      verify_trigger!
      verify_identity!
      notes = changelog_notes!
      verify_commit!
      notes
    end

    private

    def verify_trigger!
      return if @event_name == "push" && @ref_type == "tag"

      raise Error, "release requires a tag push, got #{@event_name.inspect} on #{@ref_type.inspect}"
    end

    def verify_identity!
      unless STABLE_VERSION.match?(@version)
        raise Error, "version #{@version.inspect} is not a stable version"
      end

      expected_tag = "v#{@version}"
      unless @tag == expected_tag
        raise Error, "tag #{@tag.inspect} does not match #{expected_tag.inspect}"
      end

      spec = Gem::Specification.load(File.join(@root, "mistri.gemspec"))
      raise Error, "mistri.gemspec could not be loaded" unless spec
      unless spec.name == "mistri"
        raise Error, "gemspec name is #{spec.name.inspect}, expected \"mistri\""
      end
      return if spec.version.to_s == @version

      raise Error, "gemspec version is #{spec.version}, expected #{@version}"
    end

    def changelog_notes!
      changelog = File.read(File.join(@root, "CHANGELOG.md"))
      heading = /^## \[#{Regexp.escape(@version)}\] - (\d{4}-\d{2}-\d{2})$/
      matches = changelog.to_enum(:scan, heading).map { Regexp.last_match.dup }
      unless matches.one?
        raise Error, "CHANGELOG.md must contain exactly one release heading for #{@version}"
      end

      Date.iso8601(matches.first[1])
      next_heading = changelog.index(/^## \[/, matches.first.end(0)) || changelog.length
      notes = changelog[matches.first.end(0)...next_heading].strip
      meaningful = notes.gsub(/<!--.*?-->/m, "").strip
      raise Error, "CHANGELOG.md release notes for #{@version} are empty" if meaningful.empty?

      notes
    rescue Date::Error
      raise Error, "CHANGELOG.md release date for #{@version} is invalid"
    end

    def verify_commit!
      dirty = git!("status", "--porcelain", "--untracked-files=all")
      raise Error, "release checkout is dirty:\n#{dirty}" unless dirty.empty?

      tag_commit = git!("rev-parse", "--verify", "#{@tag}^{commit}")
      head_commit = git!("rev-parse", "--verify", "HEAD^{commit}")
      main_commit = git!("rev-parse", "--verify", "#{@main_ref}^{commit}")

      unless tag_commit == head_commit
        raise Error, "tag #{@tag} points to #{tag_commit}, but the checkout is #{head_commit}"
      end

      _output, status = Open3.capture2e(
        "git", "merge-base", "--is-ancestor", tag_commit, main_commit, chdir: @root
      )
      return if status.success?

      raise Error, "tag #{@tag} is not reachable from #{@main_ref}"
    end

    def git!(*arguments)
      output, status = Open3.capture2e("git", *arguments, chdir: @root)
      raise Error, "git #{arguments.join(" ")} failed: #{output.strip}" unless status.success?

      output.strip
    end
  end
end

# The subprocess tests exercise this exit contract; SimpleCov cannot merge child coverage.
# :nocov:
if $PROGRAM_NAME == __FILE__
  verifier = Mistri::ReleaseVerifier.new(
    root: File.expand_path("..", __dir__),
    tag: ENV.fetch("GITHUB_REF_NAME", ""),
    main_ref: ENV.fetch("RELEASE_MAIN_REF", "origin/main"),
    event_name: ENV.fetch("GITHUB_EVENT_NAME", ""),
    ref_type: ENV.fetch("GITHUB_REF_TYPE", "")
  )

  begin
    verifier.verify!
    tag = ENV.fetch("GITHUB_REF_NAME")
    main_ref = ENV.fetch("RELEASE_MAIN_REF", "origin/main")
    warn "Verified #{tag} from #{main_ref}"
  rescue Mistri::ReleaseVerifier::Error, Errno::ENOENT => e
    warn "Release verification failed: #{e.message}"
    exit 1
  end
end
# :nocov:
