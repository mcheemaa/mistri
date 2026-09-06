# frozen_string_literal: true

require "bigdecimal"

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

    # Tool arguments compare as values. Numbers compare as numbers, so "$60",
    # "60" and "60.00" agree and a port cannot hide inside a longer one; text
    # agrees when the actual value carries the expected one, so "October 9,
    # 2026" still means "October 9".
    def same?(actual, expected)
      left = normalize(actual).delete("$,")
      right = normalize(expected).delete("$,")
      return BigDecimal(left) == BigDecimal(right) if [left, right].all? { |v| v.match?(NUMBER) }

      left == right || left.include?(right)
    end

    NUMBER = /\A\d+(\.\d+)?\z/

    def literal?(summary, value)
      Array(value).any? { |candidate| normalize(summary).include?(normalize(candidate)) }
    end
  end
end
