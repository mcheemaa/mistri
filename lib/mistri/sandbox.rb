# frozen_string_literal: true

module Mistri
  # Where code the model wrote runs: any object that answers
  # run(code, host:) with an Outcome. It must give the code no way out but
  # host, and stop it at a deadline and at a memory limit. A Mistri::Error
  # from host is the code's to catch. Any other error ends the run.
  module Sandbox
    Outcome = Data.define(:value, :output, :error) do
      def initialize(value: nil, output: [], error: nil)
        super
      end
    end

    # The code was stopped at its deadline or at its memory limit.
    class Stopped < Error; end
  end
end
