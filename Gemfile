# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development do
  gem "minitest"
  gem "rake"
  gem "simplecov", require: false
  gem "simplecov-cobertura", require: false
end

# Only the install-generator tests need Rails; the gem itself has zero
# runtime dependencies. The test skips itself when these are absent, so the
# matrix stays green if a Ruby outpaces Rails support.
group :rails_test do
  gem "activerecord", require: false
  gem "railties", require: false
end

# Dedicated database jobs prove both cross-process workspace claims; the
# adapters remain optional and the gem keeps zero runtime dependencies.
group :mysql_test, optional: true do
  gem "mysql2", require: false
end

group :postgres_test, optional: true do
  gem "pg", require: false
end

# Lint tools run on one Ruby in CI; their dependencies drop old rubies faster
# than the gem does, so the test matrix must not install them.
group :lint do
  gem "rubocop"
  gem "rubocop-minitest"
  gem "rubocop-rake"
end
