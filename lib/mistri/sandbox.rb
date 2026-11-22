# frozen_string_literal: true

module Mistri
  # Where code the model wrote runs. A sandbox is any object that answers
  #
  #   run(code, host:) # => Mistri::Sandbox::Outcome
  #
  # code is JavaScript, the body of an async function. host is a callable the
  # code reaches the outside through, and the only way out: it is given an
  # operation name and a Hash, and its answer or its error goes back into the
  # code. The sandbox gives the code no file, network, process or clock of the
  # host, and stops it at a deadline and at a memory limit.
  #
  # An agent given sandbox: adds the run_code tool. The adapter that ships is
  # Mistri::Sandbox::QuickJS, which a host requires by name.
  module Sandbox
    # What one run gave back: the value the code returned, what it printed,
    # and the message of an error it did not catch.
    Outcome = Data.define(:value, :output, :error) do
      def initialize(value: nil, output: [], error: nil)
        super
      end
    end

    # The code was stopped at its deadline or at its memory limit.
    class Stopped < Error; end
  end
end
