# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

# The default suite stays hermetic and fast; the integration harness runs
# live scenarios against real provider APIs on demand.
Minitest::TestTask.create(:test) do |t|
  t.test_globs = ["test/test_*.rb"]
end

Minitest::TestTask.create(:integration) do |t|
  t.test_globs = ["test/integration/test_*.rb"]
end

task default: :test
