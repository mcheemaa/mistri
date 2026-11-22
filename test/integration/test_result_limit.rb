# frozen_string_literal: true

require_relative "../support/integration"

# A result over the limit against the real APIs: the model reads the last line
# of the cut result and asks the tool again for the part it needs.
class TestResultLimitIntegration < Minitest::Test
  parallelize_me!

  Integration.scenario(self, :a_cut_result_is_asked_for_again_in_part) do |model|
    wanted = Integration.codename
    total = Integration.marker
    rows = Array.new(3_000) { |index| "order of customer-#{index}: total 100" }
    rows << "order of #{wanted}: total #{total}"
    asked = []
    orders = Mistri::Tool.define(
      "list_orders", "Lists the shop's orders, one on each line. Takes a customer to list " \
                     "only that customer's orders.",
      schema: -> { string :customer, "A customer's name" }
    ) do |args|
      customer = args["customer"].to_s
      asked << customer
      (customer.empty? ? rows : rows.grep(/#{Regexp.escape(customer)}/i)).join("\n")
    end
    agent = Mistri::Agent.new(provider: Mistri.provider(model), tools: [orders])

    result = agent.run("Call list_orders with no arguments. Then tell me the total of the " \
                       "order of #{wanted}, exactly as the tool gives it.")

    assert_predicate result, :completed?
    assert agent.session.messages.any?(&:cut), "no result was over the limit"
    assert_includes asked.map(&:downcase), wanted.downcase, "the tool was not asked again"
    assert Integration.carried?(result.text, total), "the answer lost the total"
  end
end
