# frozen_string_literal: true

require "bigdecimal"

module CompactionEval
  # Deterministic grading: a probe passes when the reply carries the expected
  # value after normalization, a yes/no probe when its first word is the
  # expected word. No judge model, so a run is reproducible and cheap.
  module Grader
    # Bumped whenever a rule here changes: rows carry it and a comparison
    # across versions is refused rather than mixing two graders' verdicts.
    VERSION = "2026-09-06.2"
    NUMBER = /\A\d+(\.\d+)?\z/

    module_function

    # Case, quoting, emphasis, currency marks, and thousands separators never
    # make two renderings of one value differ; a hyphen reads as a space, so
    # "double-counting" still carries "double count".
    def normalize(text)
      text.to_s.downcase.gsub(/[`"'*_$,]/, "").tr("-", " ").gsub(/\s+/, " ").strip
    end

    def pass?(reply, answer, match)
      answers = Array(answer).map { |candidate| normalize(candidate) }
      body = normalize(reply)
      case match
      when :yes_no then answers.include?(body[/\A(yes|no)\b/, 1])
      when :exact then answers.include?(body.sub(/[[:punct:]]+\z/, ""))
      else answers.any? { |candidate| carries?(body, candidate) }
      end
    end

    # A value that starts or ends with a digit must stand on its own: "10.3%"
    # does not carry "0.3%" and "54331" does not carry "5433", while a word
    # may still be carried by its longer form ("double counting").
    def carries?(body, candidate)
      head = candidate.match?(/\A\d/) ? "(?<![\\d.])" : ""
      tail = candidate.match?(/[\d%]\z/) ? "(?![\\d.]\\d|\\d)" : ""
      body.match?(/#{head}#{Regexp.escape(candidate)}#{tail}/)
    end

    # Tool arguments compare as values. Numbers compare as numbers, so "$60",
    # "60" and "60.00" agree and a port cannot hide inside a longer one; text
    # agrees when the actual value carries the expected one, so "October 9,
    # 2026" still means "October 9".
    def same?(actual, expected)
      left = normalize(actual)
      right = normalize(expected)
      return BigDecimal(left) == BigDecimal(right) if [left, right].all? { |v| v.match?(NUMBER) }

      left == right || carries?(left, right)
    end

    def literal?(summary, value)
      Array(value).any? { |candidate| normalize(summary).include?(normalize(candidate)) }
    end
  end
end
