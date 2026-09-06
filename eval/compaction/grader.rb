# frozen_string_literal: true

module CompactionEval
  # Deterministic grading: a probe passes when the reply carries the expected
  # value after normalization, a yes/no probe when its first word is the
  # expected word. No judge model, so a run is reproducible and cheap.
  module Grader
    module_function

    def normalize(text)
      text.to_s.downcase.gsub(/[`"'*_]/, "").gsub(/\s+/, " ").strip
    end

    def pass?(reply, answer, match)
      answers = Array(answer).map { |candidate| normalize(candidate) }
      body = normalize(reply)
      case match
      when :yes_no then answers.include?(body[/\A(yes|no)\b/, 1])
      when :exact then answers.include?(body.sub(/[[:punct:]]+\z/, ""))
      else answers.any? { |candidate| body.include?(candidate) }
      end
    end

    # Tool arguments compare as values: case, quotes, currency marks, and
    # thousands separators do not make "$3,948,820.57" a different amount.
    def same?(actual, expected)
      normalize(actual).delete("$,") == normalize(expected).delete("$,")
    end

    def literal?(summary, value)
      Array(value).any? { |candidate| normalize(summary).include?(normalize(candidate)) }
    end
  end
end
