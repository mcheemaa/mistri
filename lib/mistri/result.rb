# frozen_string_literal: true

module Mistri
  # The outcome of a run. A run either finishes, or suspends because a tool
  # needs a human's approval, or stops on abort or budget. Suspension is a
  # first-class outcome, not an error: the run returns immediately with
  # awaiting_approval? true and the pending calls, so nothing blocks waiting
  # for a decision that may come days later.
  #
  # Reads delegate to the final message, so result.text works whether the run
  # completed or suspended.
  # output is a task's validated value, nil on plain runs. usage is the
  # run's own accounting: every persisted turn plus compaction calls, summed
  # (a resumed run counts from the resume; task sums across its fix passes).
  # handed_off marks a run that ended because an ends_turn tool executed:
  # complete, but the final word was the tool's, and whatever comes next (a
  # human's answer) arrives as the next run's input.
  Result = Data.define(:message, :status, :pending, :output, :usage, :handed_off) do
    def initialize(message:, status:, pending: [], output: nil, usage: Usage.zero,
                   handed_off: false)
      super
    end

    def completed? = status == :completed
    def awaiting_approval? = status == :awaiting_approval
    def aborted? = status == :aborted
    def stopped_by_budget? = status == :budget
    def errored? = status == :error
    def handed_off? = handed_off

    def text = message&.text
    def stop_reason = message&.stop_reason
    def error_message = message&.error_message
    def tool_calls = message ? message.tool_calls : []
    def to_s = text.to_s
  end
end
