# frozen_string_literal: true

require_relative "test_helper"

class TestMistri < Minitest::Test
  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, Mistri::VERSION)
  end
end
