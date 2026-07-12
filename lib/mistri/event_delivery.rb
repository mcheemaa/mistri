# frozen_string_literal: true

module Mistri
  # Preserves subscriber exception identity across internal rescue boundaries.
  module EventDelivery
    # Tags a subscriber failure with the boundary that first observed it.
    class Failure < StandardError
      attr_reader :original, :boundary

      def initialize(original, boundary)
        @original = original
        @boundary = boundary
        super(original.message)
        set_backtrace(original.backtrace)
      end
    end

    # Wraps one subscriber and unwraps only failures that it created.
    class Boundary
      def initialize(subscriber, passthrough: [])
        @subscriber = subscriber
        @passthrough = passthrough.freeze
        @callable = method(:call).to_proc
      end

      def to_proc = @callable

      def call(event)
        @subscriber.call(event)
      rescue Failure
        raise
      rescue StandardError => e
        raise if @passthrough.any? { |error_class| e.is_a?(error_class) }

        raise Failure.new(e, self)
      end

      def unwrap(error)
        error.boundary.equal?(self) ? error.original : error
      end
    end

    module_function

    def wrap(subscriber, passthrough: [])
      Boundary.new(subscriber, passthrough: passthrough) if subscriber
    end

    def unwrap(error, boundary)
      return error unless error.is_a?(Failure) && boundary

      boundary.unwrap(error)
    end

    def original(error)
      error.is_a?(Failure) ? error.original : error
    end
  end
  private_constant :EventDelivery
end
