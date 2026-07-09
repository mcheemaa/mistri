# frozen_string_literal: true

require "json"

module Mistri
  module Providers
    # A scriptable provider: it streams each scripted turn as a well-formed
    # event sequence and returns the assembled assistant message, so hosts test
    # agent behavior hermetically while exercising real streaming semantics.
    #
    #   provider = Mistri::Providers::Fake.new(turns: [
    #     { text: "Hello!" },
    #     { tool_calls: [{ name: "search", arguments: { "q" => "ruby" } }] },
    #   ])
    #
    # A turn may combine :thinking, :text, and :tool_calls, or carry :error to
    # stream a failed turn. :stop_reason overrides the inferred reason.
    class Fake
      MODEL = "fake-1"

      # Every #stream call is recorded here, so a test can assert what the
      # agent actually sent.
      attr_reader :requests

      def model = MODEL

      def initialize(turns: [], chunk_size: 12)
        @turns = turns.map { |turn| turn.transform_keys(&:to_sym) }
        @prices_usage = @turns.all? do |turn|
          !turn[:usage] || turn[:usage].cost.known?
        end
        @chunk_size = [chunk_size, 1].max
        @requests = []
      end

      def prices_usage? = @prices_usage

      def stream(messages: [], **options, &emit)
        # Snapshot the array: the loop appends replies to it in place.
        @requests << { messages: messages.dup, options: }
        turn = @turns.shift
        raise ConfigurationError, "fake provider has no scripted turns left" unless turn

        blocks = []
        emit_event(emit, :start, blocks)
        return finish_error(turn, blocks, emit) if turn[:error]

        stream_block(:thinking, turn[:thinking], blocks, emit) if turn[:thinking]
        stream_block(:text, turn[:text], blocks, emit) if turn[:text]
        Array(turn[:tool_calls]).each_with_index do |call, position|
          stream_tool_call(call, position, blocks, emit)
        end
        finish(turn, blocks, emit)
      end

      private

      def stream_block(kind, full_text, blocks, emit)
        index = blocks.size
        emit_event(emit, :"#{kind}_start", blocks, content_index: index)
        built = +""
        full_text.scan(/.{1,#{@chunk_size}}/m) do |chunk|
          built << chunk
          emit_event(emit, :"#{kind}_delta", blocks + [build_block(kind, built)],
                     content_index: index, delta: chunk)
        end
        blocks << build_block(kind, full_text)
        emit_event(emit, :"#{kind}_end", blocks, content_index: index, content: full_text)
      end

      def build_block(kind, text)
        kind == :text ? Content::Text.new(text:) : Content::Thinking.new(thinking: text)
      end

      # Arguments stream in chunks, and every delta's partial carries the
      # in-progress call with the arguments parsed so far, the same shape a
      # real assembler builds, so a consumer that renders tool input as it
      # arrives (a page preview, a code block) is testable headless.
      def stream_tool_call(spec, position, blocks, emit)
        spec = spec.transform_keys(&:to_sym)
        call = ToolCall.new(id: spec[:id] || "call_#{position + 1}", name: spec[:name],
                            arguments: (spec[:arguments] || {}).transform_keys(&:to_s))
        index = blocks.size
        emit_event(emit, :toolcall_start, blocks, content_index: index)
        built = +""
        JSON.generate(call.arguments).scan(/.{1,#{@chunk_size}}/m) do |chunk|
          built << chunk
          emit_event(emit, :toolcall_delta, blocks + [in_progress(call, built)],
                     content_index: index, delta: chunk)
        end
        blocks << call
        emit_event(emit, :toolcall_end, blocks, content_index: index, tool_call: call)
      end

      def in_progress(call, json)
        parsed = PartialJson.parse(json)
        ToolCall.new(id: call.id, name: call.name,
                     arguments: parsed.is_a?(Hash) ? parsed : {})
      end

      def finish(turn, blocks, emit)
        reason = turn[:stop_reason] ||
                 (blocks.any?(ToolCall) ? StopReason::TOOL_USE : StopReason::STOP)
        message = assemble(blocks, usage: turn[:usage] || Usage.zero, stop_reason: reason)
        emit&.call(Event.new(type: :done, reason:, message:))
        message
      end

      def finish_error(turn, blocks, emit)
        error = { "type" => turn.fetch(:error_type, "Error") }
        error["status"] = turn[:status] if turn[:status]
        message = assemble(blocks, usage: turn[:usage] || Usage.zero, stop_reason: StopReason::ERROR,
                                   error_message: turn[:error], error: error)
        emit&.call(Event.new(type: :error, reason: StopReason::ERROR, message:,
                             error_message: turn[:error]))
        message
      end

      def assemble(blocks, **meta)
        Message.assistant(content: blocks, model: MODEL, provider: :fake, **meta)
      end

      def emit_event(emit, type, blocks, **fields)
        emit&.call(Event.new(type:, partial: assemble(blocks), **fields))
      end
    end
  end
end
