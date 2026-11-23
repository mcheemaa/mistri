# frozen_string_literal: true

module Mistri
  module Test
    # Runs a script of host operations in place of JavaScript.
    class ScriptedSandbox
      def run(code, host:)
        value = JSON.parse(code).map do |operation, payload|
          host.call(operation, payload)
        rescue Mistri::Error => e
          "threw: #{e.message}"
        end
        Mistri::Sandbox::Outcome.new(value:, output: ["printed"])
      end
    end

    # Runs one script through an agent and returns what each operation answered.
    module ScriptedRuns
      def answers(script, **)
        calls = [{ name: "run_code", arguments: { code: JSON.generate(script) } }]
        provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
        agent = Mistri::Agent.new(provider:, sandbox: ScriptedSandbox.new, **)
        agent.run("go")
        [JSON.parse(agent.session.messages.find(&:tool?).text.lines.last), agent]
      end
    end
  end
end
