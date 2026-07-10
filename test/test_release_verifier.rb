# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "test_helper"
require_relative "../script/verify_release"

class TestReleaseVerifier < Minitest::Test
  VERSION = "1.2.3"
  TAG = "v#{VERSION}".freeze

  def setup
    @root = Dir.mktmpdir("mistri-release")
    write_fixture
    git!("init", "--quiet")
    git!("config", "user.email", "test@example.com")
    git!("config", "user.name", "Mistri Test")
    git!("add", ".")
    git!("commit", "--quiet", "--message", "Prepare release")
    git!("branch", "--move", "main")
    git!("tag", TAG)
    git!("update-ref", "refs/remotes/origin/main", "HEAD")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_accepts_the_exact_tagged_release_on_main
    notes = verifier.verify!

    assert_equal "- Ship the release.", notes
  end

  def test_rejects_a_manual_or_non_tag_trigger
    error = assert_raises(Mistri::ReleaseVerifier::Error) do
      verifier(event_name: "workflow_dispatch", ref_type: "branch").verify!
    end

    assert_match(/requires a tag push/, error.message)
  end

  def test_rejects_a_tag_or_gemspec_version_mismatch
    error = assert_raises(Mistri::ReleaseVerifier::Error) do
      verifier(tag: "v1.2.4").verify!
    end
    assert_match(/does not match/, error.message)

    File.write(File.join(@root, "mistri.gemspec"), gemspec("1.2.4"))
    error = assert_raises(Mistri::ReleaseVerifier::Error) { verifier.verify! }
    assert_match(/gemspec version/, error.message)
  end

  def test_rejects_missing_empty_or_duplicate_release_notes
    changelog = File.join(@root, "CHANGELOG.md")
    File.write(changelog, "# Changelog\n\n## [Unreleased]\n")
    assert_raises(Mistri::ReleaseVerifier::Error) { verifier.verify! }

    File.write(changelog, "# Changelog\n\n## [#{VERSION}] - 2026-07-10\n\n<!-- later -->\n")
    error = assert_raises(Mistri::ReleaseVerifier::Error) { verifier.verify! }
    assert_match(/notes.*empty/, error.message)

    File.write(changelog, <<~CHANGELOG)
      # Changelog

      ## [#{VERSION}] - 2026-07-10

      - First copy.

      ## [#{VERSION}] - 2026-07-09

      - Second copy.
    CHANGELOG
    error = assert_raises(Mistri::ReleaseVerifier::Error) { verifier.verify! }
    assert_match(/exactly one/, error.message)
  end

  def test_rejects_a_checkout_other_than_the_tag
    File.write(File.join(@root, "README.md"), "later\n")
    git!("add", "README.md")
    git!("commit", "--quiet", "--message", "Move past release")
    git!("update-ref", "refs/remotes/origin/main", "HEAD")

    error = assert_raises(Mistri::ReleaseVerifier::Error) { verifier.verify! }

    assert_match(/checkout/, error.message)
  end

  def test_rejects_a_dirty_checkout
    File.write(File.join(@root, "README.md"), "dirty\n")

    error = assert_raises(Mistri::ReleaseVerifier::Error) { verifier.verify! }

    assert_match(/checkout is dirty/, error.message)
  end

  def test_rejects_a_tag_that_is_not_on_main
    main_commit = git!("rev-parse", "HEAD")
    git!("switch", "--quiet", "--orphan", "release-side")
    write_fixture
    git!("add", ".")
    git!("commit", "--quiet", "--message", "Side release")
    git!("tag", "--force", TAG)
    git!("update-ref", "refs/remotes/origin/main", main_commit)

    error = assert_raises(Mistri::ReleaseVerifier::Error) { verifier.verify! }

    assert_match(/not reachable/, error.message)
  end

  private

  def verifier(tag: TAG, event_name: "push", ref_type: "tag")
    Mistri::ReleaseVerifier.new(
      root: @root,
      tag: tag,
      main_ref: "origin/main",
      event_name: event_name,
      ref_type: ref_type,
      version: VERSION
    )
  end

  def write_fixture
    FileUtils.mkdir_p(File.join(@root, "lib"))
    File.write(File.join(@root, "README.md"), "fixture\n")
    File.write(File.join(@root, "mistri.gemspec"), gemspec(VERSION))
    File.write(File.join(@root, "CHANGELOG.md"), <<~CHANGELOG)
      # Changelog

      ## [Unreleased]

      ## [#{VERSION}] - 2026-07-10

      - Ship the release.
    CHANGELOG
  end

  def gemspec(version)
    <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "mistri"
        spec.version = "#{version}"
        spec.authors = ["Test"]
        spec.summary = "Test gem"
        spec.files = []
      end
    RUBY
  end

  def git!(*arguments)
    clean_env = ENV.each_key.grep(/\AGIT_CONFIG_/).to_h { |key| [key, nil] }.merge(
      "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_CONFIG_NOSYSTEM" => "1",
      "HOME" => @root,
      "XDG_CONFIG_HOME" => @root
    )
    output, status = Open3.capture2e(
      clean_env,
      "git", "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false", *arguments,
      chdir: @root
    )
    raise "git #{arguments.join(" ")} failed: #{output}" unless status.success?

    output.strip
  end
end
