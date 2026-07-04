# frozen_string_literal: true

require_relative "test_helper"

class TestAbortSignal < Minitest::Test
  def test_latches_once_with_a_reason
    signal = Mistri::AbortSignal.new
    signal.abort!(:user_stop)
    signal.abort!(:too_late)

    assert_predicate signal, :aborted?
    assert_equal :user_stop, signal.reason
  end

  def test_callbacks_fire_exactly_once_on_abort
    signal = Mistri::AbortSignal.new
    fired = 0
    signal.on_abort { fired += 1 }

    signal.abort!
    signal.abort!

    assert_equal 1, fired
  end

  def test_a_callback_added_after_abort_fires_immediately
    signal = Mistri::AbortSignal.new
    signal.abort!
    fired = false

    signal.on_abort { fired = true }

    assert fired
  end

  def test_a_removed_callback_never_fires
    signal = Mistri::AbortSignal.new
    fired = false
    handle = signal.on_abort { fired = true }
    signal.remove_callback(handle)

    signal.abort!

    refute fired
  end

  def test_a_raising_callback_does_not_strand_the_others
    signal = Mistri::AbortSignal.new
    reached = false
    signal.on_abort { raise "boom" }
    signal.on_abort { reached = true }

    signal.abort!

    assert reached
  end
end
