# frozen_string_literal: true

require_relative "../support/integration"

# run_code against the real APIs: the model adds up a saved result in code
# that no model adds up by reading. It needs the wasmtime gem and
# MISTRI_QUICKJS_WASM, the file quickjs.wasm of the npm package quickjs-wasi.
class TestRunCodeIntegration < Minitest::Test
  parallelize_me!

  def self.sandbox
    return @sandbox if defined?(@sandbox)

    @sandbox = begin
      require "mistri/sandbox/quickjs"
      Mistri::Sandbox::QuickJS.new(wasm: ENV.fetch("MISTRI_QUICKJS_WASM"))
    rescue LoadError, KeyError
      nil
    end
  end

  Integration.scenario(self, :a_sum_over_a_saved_result_is_computed_in_code) do |model|
    skip "the wasmtime gem or MISTRI_QUICKJS_WASM is missing" unless self.class.sandbox

    random = Random.new(Integration.marker.hash)
    orders = Array.new(1_500) do |index|
      { "id" => index + 1, "status" => %w[shipped pending cancelled][random.rand(3)],
        "total" => random.rand(100_000) / 100.0 }
    end
    cancelled = orders.select { |order| order["status"] == "cancelled" }
    sum = format("%.2f", cancelled.sum { |order| order["total"] })
    list = Mistri::Tool.define("list_orders", "Lists every order of the shop as JSON.") do
      JSON.generate(orders)
    end
    agent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [list],
                              scratchpad: Mistri::Workspace::Memory.new,
                              sandbox: self.class.sandbox)

    result = agent.run("Call list_orders. Then tell me the sum of total over the orders with " \
                       "the status cancelled, with two decimals.")

    assert_predicate result, :completed?
    assert_includes agent.session.messages.flat_map(&:tool_calls).map(&:name), "run_code"
    assert Integration.number?(result.text.delete(","), sum), "the answer is not #{sum}"
  end
end
