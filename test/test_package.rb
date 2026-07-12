# frozen_string_literal: true

require "fileutils"
require "bundler"
require "open3"
require "pathname"
require "rbconfig"
require "rubygems/package"
require "tmpdir"
require_relative "test_helper"

# The package smoke test exercises the artifact a user installs, outside Bundler and the checkout.
class TestPackage < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SHIPPED_ROOT_FILES = %w[CHANGELOG.md CONTRIBUTING.md LICENSE NOTICE README.md SECURITY.md
                          UPGRADING.md mistri.gemspec].freeze

  def test_strict_package_installs_and_loads_in_isolation
    Dir.mktmpdir("mistri-package") do |temporary|
      gem_path = File.join(temporary, "mistri-#{Mistri::VERSION}.gem")
      clean_env = isolated_environment(temporary)

      run!(clean_env, RbConfig.ruby, "-S", "gem", "build", "mistri.gemspec", "--strict",
           "--output", gem_path, chdir: ROOT)
      verify_specification(gem_path)

      outside = File.join(temporary, "outside")
      FileUtils.mkdir_p(outside)
      run!(clean_env, RbConfig.ruby, "-S", "gem", "install", gem_path, "--local",
           "--no-document", chdir: outside)
      run!(clean_env, RbConfig.ruby, "-e", installed_smoke, chdir: outside)
    end
  end

  private

  def verify_specification(gem_path)
    spec = Gem::Package.new(gem_path).spec

    assert_equal "mistri", spec.name
    assert_equal Mistri::VERSION, spec.version.to_s
    assert_empty spec.runtime_dependencies
    assert_equal ["lib"], spec.require_paths
    assert_empty spec.executables
    assert_equal "https://rubygems.org", spec.metadata["allowed_push_host"]
    assert_equal "true", spec.metadata["rubygems_mfa_required"]
    assert_equal "https://github.com/mcheemaa/mistri/blob/v#{Mistri::VERSION}/docs/README.md",
                 spec.metadata["documentation_uri"]
    assert_equal expected_files, spec.files.sort
  end

  def expected_files
    libraries = Dir.glob(File.join(ROOT, "lib", "**", "*"))
                   .select { |path| File.file?(path) }
                   .map { |path| Pathname(path).relative_path_from(Pathname(ROOT)).to_s }
    documentation = Dir.glob(File.join(ROOT, "docs", "**", "*.md"))
                       .map { |path| Pathname(path).relative_path_from(Pathname(ROOT)).to_s }
    public_assets = %w[assets examples].flat_map do |directory|
      Dir.glob(File.join(ROOT, directory, "**", "*"))
         .select { |path| File.file?(path) }
         .map { |path| Pathname(path).relative_path_from(Pathname(ROOT)).to_s }
    end
    (libraries + documentation + public_assets + SHIPPED_ROOT_FILES).sort
  end

  def isolated_environment(temporary)
    gem_home = File.join(temporary, "gems")
    ENV.each_key.grep(/\ABUNDLE_/).to_h { |key| [key, nil] }.merge(
      "GEM_HOME" => gem_home,
      "GEM_PATH" => gem_home,
      "GEMRC" => File::NULL,
      "HOME" => File.join(temporary, "home"),
      "RUBYGEMS_GEMDEPS" => nil,
      "RUBYLIB" => nil,
      "RUBYOPT" => nil
    )
  end

  def installed_smoke
    <<~'RUBY'
      require "mistri"
      require "mistri/locks/rails_cache"
      require "mistri/stores/active_record"
      require "mistri/workspace/active_record"

      spec = Gem.loaded_specs.fetch("mistri")
      loaded = $LOADED_FEATURES.find { |path| path.end_with?("/mistri.rb") }
      abort "mistri loaded outside its installed gem" unless loaded &&
        File.realpath(loaded).start_with?("#{File.realpath(spec.full_gem_path)}/")
      abort "wrong installed version" unless Mistri::VERSION == spec.version.to_s
    RUBY
  end

  def run!(environment, *command, chdir:)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e(environment, *command, chdir: chdir)
    end

    assert_predicate status, :success?, "#{command.join(" ")} failed:\n#{output}"
  end
end
