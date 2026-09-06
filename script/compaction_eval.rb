#!/usr/bin/env ruby
# frozen_string_literal: true

# The compaction eval command. Paid: it calls real providers.
#
#   bundle exec ruby script/compaction_eval.rb run
#   bundle exec ruby script/compaction_eval.rb run --models all --sizes S,M,L --folds --baselines
#   bundle exec ruby script/compaction_eval.rb report tmp/compaction-eval/<file>.jsonl
#   bundle exec ruby script/compaction_eval.rb compare eval/baselines/current.jsonl <new>.jsonl
#   bundle exec ruby script/compaction_eval.rb distill <file>.jsonl eval/baselines/current.jsonl
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
  # The command: runs a matrix, renders or compares results, and rewrites
  # stored rows through the current grader or into a committable baseline.
  class CLI
    DEFAULT_MODELS = %w[claude-sonnet-5 gpt-5.6-sol gemini-2.5-flash].freeze
    ENV_FILE = File.join(ROOT, ".env.development.local")
    USAGE = "usage: compaction_eval.rb run [options] | report FILE | compare BASE CANDIDATE | " \
            "regrade FILE OUT | distill FILE OUT | list"

    def self.start(argv)
      new.start(argv)
    end

    # The two seams a test needs: where keys come from and how a model id
    # becomes a provider.
    def initialize(env_file: ENV_FILE, provider_for: ->(model) { Mistri.provider(model) })
      @env_file = env_file
      @provider_for = provider_for
    end

    def start(argv)
      case argv.shift
      when "run" then run(argv)
      when "report" then puts Report.markdown(Report.read(argv.fetch(0)))
      when "compare" then compare(argv.fetch(0), argv.fetch(1))
      when "regrade" then rewrite(argv.fetch(0), argv.fetch(1)) { |row| Runner.regrade(row) }
      when "distill" then rewrite(argv.fetch(0), argv.fetch(1)) { |row| Runner.distill(row) }
      when "list" then list
      else
        warn USAGE
        exit 2
      end
    end

    private

    def run(argv)
      options = { models: DEFAULT_MODELS, scenarios: Scenario.names, sizes: %w[S], repeat: 1,
                  seed: 1, folds: false, baselines: false, reader: nil, judge: :auto }
      files = { out: nil, prompts: nil }
      parser(options, files).parse!(argv)
      load_env
      load files[:prompts] if files[:prompts]
      out = files[:out] || default_out
      FileUtils.mkdir_p(File.dirname(out))
      rows = File.open(out, "w") do |file|
        file.sync = true
        Runner.new(**options, provider_for: @provider_for,
                              on_row: ->(row) { file.puts(JSON.generate(row)) }).run
      end
      File.write(out.sub(/\.jsonl\z/, ".md"), Report.markdown(rows))
      puts Report.markdown(rows)
      puts "\nrows: #{out}"
    end

    def parser(options, files)
      OptionParser.new do |opts|
        opts.banner = "usage: compaction_eval.rb run [options]"
        matrix_options(opts, options)
        grading_options(opts, options)
        opts.on("--out FILE", "results file (.jsonl); a .md report lands beside it") do |f|
          files[:out] = f
        end
        opts.on("--prompts FILE", "Ruby file that redefines the compactor prompts, for local " \
                                  "iteration only") { |f| files[:prompts] = File.expand_path(f) }
      end
    end

    def matrix_options(opts, options)
      opts.on("--models LIST", "comma-separated model ids, or all") do |list|
        options[:models] = list == "all" ? Mistri::Models::CATALOG.map(&:first) : list.split(",")
      end
      opts.on("--scenarios LIST", "comma-separated scenario names") do |list|
        options[:scenarios] = list.split(",")
      end
      opts.on("--sizes LIST", "comma-separated sizes among S, M, L") do |list|
        options[:sizes] = list.split(",")
      end
      opts.on("--repeat N", Integer, "runs per cell, each with its own seed") do |n|
        options[:repeat] = n
      end
      opts.on("--seed N", Integer, "base seed for the synthetic sessions") do |n|
        options[:seed] = n
      end
      opts.on("--folds", "compact again after each later segment") { options[:folds] = true }
      opts.on("--baselines", "also probe the full history and the kept tail") do
        options[:baselines] = true
      end
    end

    def grading_options(opts, options)
      opts.on("--reader MODEL", "one model answers every probe instead of the summarizer") do |m|
        options[:reader] = m
      end
      opts.on("--judge MODEL", "judge model; auto picks Astra, or Sol when Astra is under " \
                               "test") { |m| options[:judge] = m == "auto" ? :auto : m }
      opts.on("--no-judge", "skip the judge pass") { options[:judge] = nil }
    end

    # The verdict is the exit status, so a workflow or a script can act on it.
    def compare(base, candidate)
      comparison = Report.compare(Report.read(base), Report.read(candidate))
      puts comparison.markdown
      exit 1 unless comparison.passed
    end

    # regrade applies the current grader to stored rows, so a grading fix
    # never needs another paid run; distill drops every generated word, which
    # is the form a baseline is committed in.
    def rewrite(path, out, &)
      rows = Report.read(path).map(&)
      FileUtils.mkdir_p(File.dirname(out))
      Report.write(rows, out)
      File.write(out.sub(/\.jsonl\z/, ".md"), Report.markdown(rows))
      puts Report.markdown(rows)
    end

    def list
      Scenario.names.each do |name|
        scenario = Scenario[name]
        puts format("%<name>-20s %<summary>-47s facts %<facts>2d  probes %<probes>2d  " \
                    "segments %<segments>d  digest %<digest>s",
                    name: name, summary: scenario.summary, facts: scenario.facts.length,
                    probes: scenario.probes.length, segments: scenario.segments.length,
                    digest: scenario.digest)
      end
    end

    def default_out
      File.join(ROOT, "tmp", "compaction-eval",
                "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{Runner.git_sha}.jsonl")
    end

    # The env file wins over the shell, as the test helper does, so a stale
    # exported key cannot shadow the working one.
    def load_env
      return unless File.exist?(@env_file)

      File.readlines(@env_file, chomp: true).each do |line|
        next if line.strip.empty? || line.start_with?("#")

        key, value = line.sub(/\Aexport\s+/, "").split("=", 2)
        ENV[key] = value.to_s.strip.delete_prefix('"').delete_suffix('"') if key && value
      end
    end
  end
end

CompactionEval::CLI.start(ARGV) if $PROGRAM_NAME == __FILE__
