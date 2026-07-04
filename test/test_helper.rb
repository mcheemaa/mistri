# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Live tests read provider keys from the gitignored env file; CI never has one.
env_file = File.expand_path("../.env.development.local", __dir__)
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    ENV[key] ||= value.to_s.delete_prefix('"').delete_suffix('"')
  end
end

require "mistri"
require "minitest/autorun"
