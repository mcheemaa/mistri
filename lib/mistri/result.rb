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
  Result = Data.define(:message, :status, :pending) do
    def initialize(message:, status:, pending: [])
      super
    end

    def completed? = status == :completed
    def awaiting_approval? = status == :awaiting_approval
    def aborted? = status == :aborted
    def stopped_by_budget? = status == :budget
    def errored? = status == :error

    def text = message&.text
    def stop_reason = message&.stop_reason
    def error_message = message&.error_message
    def tool_calls = message ? message.tool_calls : []
    def to_s = text.to_s
  end
end
