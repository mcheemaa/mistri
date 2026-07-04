# frozen_string_literal: true

module Mistri
  # Why an assistant turn stopped. Providers map their native finish reasons
  # onto this one set, so the loop and the host never read wire spellings.
  #
  #   :stop     - the model finished its answer
  #   :length   - it hit the max-tokens ceiling mid-turn
  #   :tool_use - it paused to call one or more tools
  #   :error    - the provider or runtime failed
  #   :aborted  - the host cancelled the turn
  module StopReason
    STOP = :stop
    LENGTH = :length
    TOOL_USE = :tool_use
    ERROR = :error
    ABORTED = :aborted

    ALL = [STOP, LENGTH, TOOL_USE, ERROR, ABORTED].freeze

    def self.valid?(reason) = ALL.include?(reason)
  end
end
