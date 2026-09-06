#!/usr/bin/env ruby
# frozen_string_literal: true

# The compaction eval command. Paid: it calls real providers.
#
#   bundle exec ruby script/compaction_eval.rb run
#   bundle exec ruby script/compaction_eval.rb run --models all --sizes S,M,L --folds --baselines
#   bundle exec ruby script/compaction_eval.rb report tmp/compaction-eval/<file>.jsonl
#   bundle exec ruby script/compaction_eval.rb compare eval/baselines/<base>.jsonl <candidate>.jsonl
#
# See eval/README.md for the matrix, the cost, and the rule for prompt changes.
require "json"
require "optparse"
require "fileutils"
require "time"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))
require File.join(ROOT, "eval", "compaction")

module CompactionEval
  class CLI
    DEFAULT_MODELS = %w[claude-haiku-4-5 gpt-5.6-sol gemini-2.5-flash].freeze
    ENV_FILE = File.join(ROOT, ".env.development.local")

    def self.start(argv)
      new.start(argv)
    end

    def start(argv)
      command = argv.shift
      case command
      when "run" then run(argv)
      when "report" then puts Report.markdown(Report.read(argv.fetch(0)))
      when "compare" then puts Report.compare(Report.read(argv.fetch(0)),
                                              Report.read(argv.fetch(1)))
      when "regrade" then regrade(argv.fetch(0), argv.fetch(1))
      when "list" then list
      else
        warn "usage: compaction_eval.rb run|report FILE|compare BASE CANDIDATE|" \
             "regrade FILE OUT|list"
        exit 2
      end
    end

    private

    def run(argv)
      options = { models: DEFAULT_MODELS, scenarios: Scenario.names, sizes: %w[S M], repeat: 1,
                  seed: 1, folds: false, baselines: false, out: nil, prompts: nil }
      parser(options).parse!(argv)
      load_env
      load options[:prompts] if options[:prompts]
      out = options.delete(:out) || default_out
      FileUtils.mkdir_p(File.dirname(out))
      rows = File.open(out, "w") do |file|
        file.sync = true
        Runner.new(**options.except(:prompts), on_row: lambda { |row|
          file.puts(JSON.generate(row))
        }).run
      end
      File.write(out.sub(/\.jsonl\z/, ".md"), Report.markdown(rows))
      puts Report.markdown(rows)
      puts "\nrows: #{out}"
    end

    def parser(options)
      OptionParser.new do |opts|
        opts.banner = "usage: compaction_eval.rb run [options]"
        opts.on("--models LIST", "comma-separated model ids, or all") do |list|
          options[:models] = list == "all" ? Mistri::Models::CATALOG.map(&:first) : list.split(",")
        end
        opts.on("--scenarios LIST", "comma-separated scenario names") do |l|
          options[:scenarios] = l.split(",")
        end
        opts.on("--sizes LIST", "comma-separated sizes among S, M, L") do |l|
          options[:sizes] = l.split(",")
        end
        opts.on("--repeat N", Integer, "runs per cell with a different seed each") do |n|
          options[:repeat] = n
        end
        opts.on("--seed N", Integer, "base seed for the synthetic sessions") do |n|
          options[:seed] = n
        end
        opts.on("--folds", "compact again after each later segment") { options[:folds] = true }
        opts.on("--baselines", "also probe the full history and the kept tail") do
          options[:baselines] = true
        end
        opts.on("--out FILE", "results file (.jsonl); a .md report lands beside it") do |f|
          options[:out] = f
        end
        opts.on("--prompts FILE", "Ruby file that redefines the compactor prompts, for local " \
                                  "iteration only") { |f| options[:prompts] = File.expand_path(f) }
      end
    end

    # Grades stored rows again with the current grader: a grading fix never
    # needs another paid run.
    def regrade(path, out)
      rows = Report.read(path).map { |row| Runner.regrade(row) }
      Report.write(rows, out)
      File.write(out.sub(/\.jsonl\z/, ".md"), Report.markdown(rows))
      puts Report.markdown(rows)
    end

    def list
      Scenario.names.each do |name|
        scenario = Scenario[name]
        puts format("%<name>-20s %<summary>-47s facts %<facts>2d  probes %<probes>2d  " \
                    "segments %<segments>d", name: name, summary: scenario.summary,
                                             facts: scenario.facts.length,
                                             probes: scenario.probes.length,
                                             segments: scenario.segments.length)
      end
    end

    def default_out
      File.join(ROOT, "tmp", "compaction-eval",
                "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{Runner.git_sha}.jsonl")
    end

    # The env file wins over the shell, as the test helper does, so a stale
    # exported key cannot shadow the working one.
    def load_env
      return unless File.exist?(ENV_FILE)

      File.readlines(ENV_FILE, chomp: true).each do |line|
        next if line.strip.empty? || line.start_with?("#")

        key, value = line.sub(/\Aexport\s+/, "").split("=", 2)
        ENV[key] = value.to_s.strip.delete_prefix('"').delete_suffix('"') if key && value
      end
    end
  end
end

CompactionEval::CLI.start(ARGV) if $PROGRAM_NAME == __FILE__
