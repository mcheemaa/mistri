# frozen_string_literal: true

require_relative "test_helper"

# What the model reads about run_code: its description, and how a run ended.
class TestRunCodeResult < Minitest::Test
  # Ends a run the way it is told to, in place of running code.
  class EndingSandbox
    def initialize(ending) = @ending = ending

    def run(_code, host:) # rubocop:disable Lint/UnusedMethodArgument -- the sandbox contract
      raise @ending if @ending.is_a?(Exception)

      Mistri::Sandbox::Outcome.new(**@ending)
    end
  end

  def test_the_result_of_run_code_says_how_the_code_ended
    endings = [{ value: "plain" }, { output: ["only printed"] }, {},
               { error: "TypeError: x is not a function" },
               Mistri::Sandbox::Stopped.new("it ran for 10 seconds")]
    results = endings.map do |ending|
      calls = [{ name: "run_code", arguments: { code: "return 1" } }]
      provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
      agent = Mistri::Agent.new(provider:, sandbox: EndingSandbox.new(ending))
      agent.run("go")
      agent.session.messages.find(&:tool?)
    end

    assert_equal ["plain", "only printed", "(the code returned nothing and printed nothing)"],
                 results.first(3).map(&:text)
    assert_equal "The code failed:\nTypeError: x is not a function", results[3].text
    assert_equal "The code did not finish: it ran for 10 seconds", results[4].text
    assert_equal [false, false, false, true, true], results.map(&:tool_error)
  end

  def test_the_description_states_the_limit_only_where_one_is_in_force
    described = lambda do |**options|
      provider = Mistri::Providers::Fake.new(turns: [{ text: "done" }])
      Mistri::Agent.new(provider:, sandbox: EndingSandbox.new({}), **options).run("go")
      provider.requests.first[:options][:tools].find { |tool| tool[:name] == "run_code" }
                                               .fetch(:description)
    end

    assert_includes described.call, "what you need to read: a result over 10000 bytes is cut."
    assert_includes described.call(result_limit: false), "what you need to read. Write a longer"
    assert_includes described.call, "or throws an error when the tool fails"
  end
end
