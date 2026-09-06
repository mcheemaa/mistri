# frozen_string_literal: true

# The compaction eval: synthetic sessions with seeded facts, real providers,
# and grading by what a resumed agent can still answer and do. A maintainer
# tool, not part of the gem: see eval/README.md.
require "mistri"
require_relative "compaction/scenario"
require_relative "compaction/filler"
require_relative "compaction/builder"
require_relative "compaction/grader"
require_relative "compaction/runner"
require_relative "compaction/report"
Dir[File.join(__dir__, "compaction", "scenarios", "*.rb")].each { |path| require path }
