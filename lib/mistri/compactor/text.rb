# frozen_string_literal: true

module Mistri
  class Compactor
    # The plain text a summarizer reads when it cannot be given the
    # conversation itself: tool calls by name and arguments, results as text,
    # thinking never (it stays in its turn).
    module Text
      class << self
        # A tool result is whole when the text fits the room, in tokens.
        # When it does not, one length makes it fit, so the longest results
        # are cut first, and never to less than the cut made when no window
        # is known.
        def of(messages, room = nil, estimator = nil)
          texts = messages.map { |message| text_of(message) }
          return render(messages, texts, TOOL_RESULT_MAX_CHARS) unless room

          whole = render(messages, texts)
          tokens = Compaction.estimate(Message.user(whole), estimator)
          return whole if tokens <= room

          results = messages.zip(texts).filter_map { |message, text| text.length if message.tool? }
          fitting = (room * whole.length / tokens) - (whole.length - results.sum)
          render(messages, texts, [shared_limit(results.sort, fitting), TOOL_RESULT_MAX_CHARS].max)
        end

        # The messages in as few runs as fit the room, each measured with
        # its long results cut. One run when no room is known.
        def parts(messages, room, estimator)
          return [messages] unless room&.positive?

          held = 0
          messages.each_with_object([[]]) do |message, runs|
            text = text_of(message)
            text = truncate_tool_result(text, TOOL_RESULT_MAX_CHARS) if message.tool?
            tokens = Compaction.estimate(Message.user(text), estimator)
            if held + tokens > room && runs.last.any?
              runs << []
              held = 0
            end
            runs.last << message
            held += tokens
          end
        end

        private

        def render(messages, texts, limit = nil)
          messages.zip(texts).map do |message, text|
            text = truncate_tool_result(text, limit) if limit && message.tool?
            "#{message.role.to_s.upcase}:\n#{text}"
          end.join("\n\n")
        end

        # The largest length such that the results, each cut to it, hold no
        # more than the characters given.
        def shared_limit(lengths, chars)
          lengths.each_with_index do |length, index|
            share = chars / (lengths.length - index)
            return share if length > share

            chars -= length
          end
          chars
        end

        def text_of(message)
          message.content.filter_map do |block|
            case block
            when Content::Text then block.text
            when Content::Image then "[image]"
            when ToolCall then "[called #{block.name} with #{JSON.generate(block.arguments)}]"
            end
          end.join("\n")
        end

        # Large tool output remains durable and unchanged on ordinary model
        # requests; only the lossy summary wire is bounded, with both ends
        # kept.
        def truncate_tool_result(text, limit)
          return text if text.length <= limit

          marker = "\n[tool result truncated; original length: #{text.length} characters]\n"
          visible = limit - marker.length
          head = (visible * 0.75).floor
          "#{text[0, head]}#{marker}#{text[-(visible - head), visible - head]}"
        end
      end
    end
  end
end
