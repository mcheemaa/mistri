# frozen_string_literal: true

# Coverage is opt-in so everyday runs stay fast; CI turns it on for one
# matrix entry and fails below the floor. Under the rake task,
# minitest/autorun loads before this file and its at_exit (running the
# tests) would fire after SimpleCov's capture; deferring the capture into
# Minitest.after_run keeps the order right either way.
if ENV["COVERAGE"] == "1"
  require "simplecov"
  if ENV["CI"]
    require "simplecov-cobertura"
    SimpleCov.formatter = SimpleCov::Formatter::CoberturaFormatter
  end
  SimpleCov.external_at_exit = defined?(Minitest) ? true : false
  SimpleCov.start do
    add_filter "/test/"
    enable_coverage :branch
    minimum_coverage line: 90
  end
  Minitest.after_run { SimpleCov.run_exit_tasks! } if defined?(Minitest)
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Live tests read provider keys from the gitignored env file; CI never has
# one. The file wins over inherited shell vars: it is this repo's stated
# intent, and a stale key exported by some other project must not ghost in.
env_file = File.expand_path("../.env.development.local", __dir__)
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    ENV[key] = value.to_s.delete_prefix('"').delete_suffix('"')
  end
end

require "mistri"
require "minitest/autorun"

module Mistri
  module Test
    ALLOW_LOOPBACK = ->(_uri, address) { address.loopback? }
  end
end
