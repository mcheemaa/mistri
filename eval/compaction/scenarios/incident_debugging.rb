# frozen_string_literal: true

# An incident at Shopify's address validation service: identifiers from tool
# output, a rollback rule, a flag that must stay off, numbers that change as
# mitigation lands, and a root cause the agent must carry into the postmortem.
# Every person, ticket, and number is invented.
CompactionEval::Scenario.define("incident_debugging",
                                summary: "Production incident with a mitigated error rate") do
  filler do |turn, rng|
    pod = "address-validation-api-#{%w[6d9f 7b21 9c4e][turn % 3]}-#{%w[x2k9 m7q1 p0d4][turn % 3]}"
    shapes = [
      { ask: "Step #{turn + 1}: pull the latest logs from #{pod} and tell me whether the " \
             "error signature is still showing up.",
        doing: "Pulling the last 200 lines from #{pod} for step #{turn + 1} and scanning " \
               "for the signature.",
        tool: "kubectl_logs",
        arguments: { "pod" => pod, "tail" => 200 },
        log: CompactionEval::Filler.request_log(rng),
        done: "Step #{turn + 1}: the signature is not in this batch, moving to the next pod." },
      { ask: "Step #{turn + 1}: what does the validation error rate look like on the " \
             "monitor over the last fifteen minutes?",
        doing: "Querying the monitor's error-rate series for step #{turn + 1}.",
        tool: "datadog_query",
        arguments: { "query" => "sum:address_validation.errors{env:production}.as_rate()",
                     "window" => "15m" },
        log: CompactionEval::Filler.metric_series(rng),
        done: "Step #{turn + 1}: the series is flat within noise. Reasoning it through: the " \
              "spikes line up with deploy windows, not with traffic, which points at the " \
              "code path rather than load." },
      { ask: "Step #{turn + 1}: run the address type specs locally against the current branch.",
        doing: "Running the address type spec file for step #{turn + 1}.",
        tool: "run_command",
        arguments: { "command" => "bin/rspec spec/services/address_type_spec.rb" },
        log: CompactionEval::Filler.rspec_output(rng),
        done: "Step #{turn + 1}: the suite is green apart from the known failure; nothing new." },
      { ask: "Step #{turn + 1}: is the health endpoint answering from all three pods?",
        doing: "Curling the health endpoint on each pod for step #{turn + 1}.",
        tool: "run_command",
        arguments: { "command" => "for p in a b c; do curl -s -i " \
                                  "http://address-validation-api-$p:8080/healthz | head -1; done" },
        log: CompactionEval::Filler.health_checks(rng),
        done: "Step #{turn + 1}: all three pods answer 200, so the failure is inside request " \
              "handling, not readiness." }
    ]
    CompactionEval::Filler.turn(turn, rng, shapes)
  end

  segment do
    fact :incident, "INC-4471",
         at: 0.0,
         text: "We are on incident %<value>s: address-validation-api is failing validation " \
               "for some checkout addresses.",
         probe: "Which incident id is this? Reply with the id only."
    fact :service, "address-validation-api",
         at: 0.0,
         text: "The affected service is %<value>s; nothing else is paging.",
         probe: "Which service is affected? Reply with the service name only."
    fact :no_force, "no",
         at: 0.02, match: :yes_no,
         text: "Rule: never force-push to main; a rollback is a new revert commit.",
         probe: "May you force-push to main to roll back? Answer yes or no."
    fact :flag, "checkout-address-type-inference",
         at: 0.05,
         text: "The feature flag %<value>s stays OFF in production until Tamsin signs off.",
         probe: "Which feature flag must stay off in production? Reply with the flag key only."
    fact :flag_state, "no",
         at: 0.05, match: :yes_no,
         text: "Nobody turns that flag on in production before the sign-off.",
         probe: "Is the flag allowed on in production right now? Answer yes or no."
    fact :on_call, "Tamsin Okoye",
         at: 0.1,
         text: "%<value>s is on call and owns the incident channel.",
         probe: "Who is on call for this incident? Reply with the name only."
    fact :monitor, "7723118",
         at: 0.15,
         text: "The Datadog monitor that paged is %<value>s.",
         probe: "Which Datadog monitor id paged? Reply with the number only."
    fact :error_rate, "4.2%",
         at: 0.2, carrier: :assistant,
         text: "The monitor shows an error rate of %<value>s on address validation right now.",
         probe: "What is the current error rate on address validation? Reply with the " \
                "percentage only."
    fact :commit, "9f2a0fe4",
         at: 0.25,
         text: "The suspect deploy is commit %<value>s, shipped this morning.",
         probe: "Which commit is the suspect deploy? Reply with the short SHA only."
    fact :error, "NoMethodError: undefined method 'zip' for nil",
         at: 0.35, carrier: :tool, answer: "undefined method 'zip' for nil",
         text: "ERROR %<value>s\n  app/services/addresses/normalize.rb:57:in `postal_parts'",
         probe: "What exact exception is in the logs? Quote the error message."
    fact :failing_spec, "spec/services/address_type_spec.rb:88",
         at: 0.4, carrier: :tool,
         text: "rspec ./%<value>s # AddressType normalizes PO boxes",
         probe: "Which spec fails, file and line? Reply with file:line only."
    fact :root_cause, "PO box addresses arrive with a nil street line",
         at: 0.5, carrier: :assistant, answer: %w[nil PO],
         text: "Root cause: %<value>s, and normalize.rb calls zip on it.",
         probe: "What is the root cause? Answer briefly."
    fact :timeout_env, "SHIPPING_RATES_TIMEOUT_MS=2500",
         at: 0.55, carrier: :tool, answer: "2500",
         text: "%<value>s",
         probe: "What is SHIPPING_RATES_TIMEOUT_MS set to in the pod? Reply with the number only."
    fact :request_id, "req_8f3a91c2",
         at: 0.6, carrier: :tool_deep,
         text: "ERROR trace sample request_id=%<value>s recipient=redacted street=nil",
         probe: "Which request id carried the failing trace sample? Reply with the id only."
    change :error_rate, "0.3%",
           at: 0.7, carrier: :assistant,
           text: "After the mitigation the error rate is down to %<value>s and holding."
    fact :freeze, "Monday",
         at: 0.75,
         text: "Deploy freeze until %<value>s: only the revert goes out before then.",
         probe: "Until which day is the deploy freeze? Reply with the day only."
    fact :next_step, "regression spec",
         at: 0.85, carrier: :assistant,
         text: "Next I write the %<value>s for PO boxes, then open the revert.",
         probe: "What is the next step before the revert? Answer briefly."
  end

  segment do
    fact :postmortem_due, "Wednesday",
         at: 0.1,
         text: "The postmortem doc is due %<value>s.",
         probe: "When is the postmortem due? Reply with the day only."
    change :freeze, "Tuesday",
           at: 0.4,
           text: "Release management shortened the freeze: it lifts %<value>s."
    fact :revert_pr, "#3481",
         at: 0.7, carrier: :tool,
         text: "Created pull request %<value>s: Revert address type normalization",
         probe: "Which pull request holds the revert? Reply with the number only."
  end

  continuation prompt: "Tamsin asked for the postmortem stub now. Call file_postmortem once with " \
                       "the incident id, the root cause, the on-call name, and the current error " \
                       "rate.",
               tool: "file_postmortem",
               description: "Opens the postmortem document with the incident facts.",
               schema: lambda {
                 string :incident_id, "Incident identifier", required: true
                 string :root_cause, "One sentence root cause", required: true
                 string :on_call, "On-call engineer", required: true
                 string :error_rate, "Current error rate", required: true
               },
               expected: lambda { |latest|
                 { "incident_id" => latest[:incident], "on_call" => latest[:on_call],
                   "error_rate" => latest[:error_rate] }
               }
end
