# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "open3"
require_relative "test/support/integration_models"

# The default suite stays hermetic and fast. The live files and the integration
# scenarios call real provider APIs on demand, and wait on the network, so their
# tests run on threads.
THREADS = %(ENV["MT_CPU"] ||= "8")
LIVE = %(ENV["MISTRI_LIVE"] = "1"; #{THREADS}).freeze
# These two files are most of a live run's cost. They cover the compactor and the
# replay of thinking, so they run when that code changes.
COMPACTION_LIVE = %w[
  test/test_compaction_eval_live.rb test/test_prefix_bound_compaction_live.rb
].freeze

Minitest::TestTask.create(:test) do |t|
  t.test_globs = ["test/test_*.rb"]
end

Minitest::TestTask.create(:live) do |t|
  t.test_globs = Dir["test/test_*_live.rb"] - COMPACTION_LIVE
  t.test_prelude = LIVE
end

Minitest::TestTask.create("live:compaction") do |t|
  t.test_globs = COMPACTION_LIVE
  t.test_prelude = LIVE
end

Minitest::TestTask.create("integration:scenarios") do |t|
  t.test_globs = ["test/integration/test_*.rb"]
  t.test_prelude = THREADS
end

desc "Run the integration scenarios, one process for each model"
task :integration do
  runs = Integration.models.map do |model|
    Thread.new do
      Open3.capture2e({ "MISTRI_INTEGRATION_MODELS" => model },
                      Gem.ruby, "-S", "rake", "integration:scenarios")
    end
  end
  results = runs.map(&:value)
  puts results.map(&:first)
  abort unless results.all? { |_output, status| status.success? }
end

task default: :test
