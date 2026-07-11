# frozen_string_literal: true

require_relative "test_helper"

# Tool hooks: the programmatic gates around execution. before_tool blocks
# with an in-band reason; after_tool rewrites results; both compose with the
# human-approval arc.
class TestAgentHooks < Minitest::Test
  def two_call_turns
    [{ tool_calls: [{ name: "read", arguments: {} },
                    { name: "purge", arguments: {} }] },
     { text: "understood" }]
  end

  def tools(log)
    [Mistri::Tool.define("read", "Reads.") do
       log << :read
       "data"
     end,
     Mistri::Tool.define("purge", "Purges.") do
       log << :purge
       "purged"
     end]
  end

  def test_before_tool_blocks_with_an_in_band_reason
    log = []
    policy = ->(call, _context) { "org policy forbids purging" if call.name == "purge" }
    provider = Mistri::Providers::Fake.new(turns: two_call_turns)
    agent = Mistri::Agent.new(provider:, tools: tools(log), before_tool: policy)

    events = []
    result = agent.run("clean up") { |event| events << event }

    assert_predicate result, :completed?
    assert_equal [:read], log, "the blocked tool never ran"

    answers = agent.session.messages.select(&:tool?)

    assert_equal %w[read purge], answers.map(&:tool_name)
    assert_equal ["data", "Blocked: org policy forbids purging"], answers.map(&:text)
    errors = answers.map(&:tool_error)
    starts = events.select { |event| event.type == :tool_started }
                   .map { |event| event.tool_call.name }
    results = events.select { |event| event.type == :tool_result }
                    .map { |event| event.tool_call.name }

    assert_equal [false, true], errors
    assert_equal ["read"], starts
    assert_equal %w[read purge], results
  end

  def test_before_tool_outranks_the_approval_gate
    gated = Mistri::Tool.define("send", "S.", needs_approval: true) { "sent" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send", arguments: {} }] },
                                             { text: "ok" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [gated],
                              before_tool: ->(_call, _context) { "not during freeze" })

    result = agent.run("send it")

    assert_predicate result, :completed?, "blocked, so nothing parked for a human"
    assert_empty agent.session.open_approvals
  end

  def test_an_approved_call_is_screened_again_at_settle_time
    ran = []
    gated = Mistri::Tool.define("send", "S.", needs_approval: true) do
      ran << :sent
      "sent"
    end
    frozen = false
    policy = ->(_call, _context) { "policy changed since approval" if frozen }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "send", arguments: {} }] },
                                             { text: "noted" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [gated], before_tool: policy)

    suspended = agent.run("send it")
    agent.session.approve(suspended.pending.first.id)
    frozen = true

    result = agent.resume

    assert_predicate result, :completed?
    assert_empty ran, "the aged approval did not outrank current policy"
    assert_includes agent.session.messages.select(&:tool?).map(&:text),
                    "Blocked: policy changed since approval"
  end

  def test_a_raising_before_hook_blocks_conservatively
    log = []
    provider = Mistri::Providers::Fake.new(turns: two_call_turns)
    agent = Mistri::Agent.new(provider:, tools: tools(log),
                              before_tool: ->(_call, _context) { raise "policy store down" })

    result = agent.run("go")

    assert_predicate result, :completed?
    assert_empty log, "nothing runs when policy cannot answer"
    assert(agent.session.messages.select(&:tool?)
                .all? { |m| m.text.include?("before_tool hook failed") })
  end

  def test_after_tool_rewrites_both_channels
    tool = Mistri::Tool.define("lookup", "L.") { "ssn: 123-45-6789" }
    redact = lambda do |_call, result, _context|
      Mistri::ToolResult.new(content: result.to_s.gsub(/\d[\d-]+/, "[redacted]"),
                             ui: { "redacted" => true })
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "lookup", arguments: {} }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool], after_tool: redact)

    agent.run("look it up")

    answer = agent.session.messages.select(&:tool?).last

    assert_equal "ssn: [redacted]", answer.text
    assert_equal({ "redacted" => true }, answer.ui)
  end

  def test_after_tool_nil_keeps_the_original_and_raises_answer_in_band
    keep = ->(_call, _result, _context) {}
    tool = Mistri::Tool.define("lookup", "L.") { "original" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "lookup", arguments: {} }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool], after_tool: keep)
    agent.run("go")

    assert_equal "original", agent.session.messages.select(&:tool?).last.text

    boom = ->(_call, _result, _context) { raise "audit sink down" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "lookup", arguments: {} }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool], after_tool: boom)
    agent.run("go")

    answer = agent.session.messages.select(&:tool?).last

    assert_includes answer.text, "after_tool hook"
    assert_includes answer.text, "already returned"
    assert_predicate answer, :tool_error?
  end

  def test_after_tool_sees_typed_failures_and_cannot_clear_them
    seen = nil
    tool = Mistri::Tool.define("boom", "B.") { raise "secret detail" }
    redact = lambda do |_call, result, _context|
      seen = result
      Mistri::ToolResult.new(content: "The operation failed.", error: false)
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "boom", arguments: {} }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool], after_tool: redact)

    agent.run("go")

    assert_instance_of Mistri::ToolResult, seen
    assert_predicate seen, :error?
    answer = agent.session.messages.select(&:tool?).last

    assert_equal "The operation failed.", answer.text
    assert_predicate answer, :tool_error?
  end

  def test_after_tool_stays_interleaved_with_each_persisted_result
    observed = []
    audit = lambda do |call, result, context|
      persisted = context.session.entries.count do |entry|
        entry["type"] == "message" && entry.dig("message", "role") == "tool"
      end
      observed << [call.name, persisted]
      context.emit.call(Mistri::Event.new(type: :compacting, content: call.name))
      result
    end
    provider = Mistri::Providers::Fake.new(turns: two_call_turns)
    events = []
    agent = Mistri::Agent.new(provider:, tools: tools([]), after_tool: audit,
                              max_concurrency: 1)

    agent.run("go") { |event| events << event }

    assert_equal [["read", 0], ["purge", 1]], observed
    lifecycle = events.filter_map do |event|
      case event.type
      when :compacting then "hook:#{event.content}"
      when :tool_result then "result:#{event.tool_call.name}"
      end
    end

    assert_equal %w[hook:read result:read hook:purge result:purge], lifecycle
  end

  def test_hooks_receive_the_callers_context
    seen = []
    peek = lambda do |_call, context|
      seen << context.session.id
      nil
    end
    tool = Mistri::Tool.define("noop", "N.") { "ok" }
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "noop", arguments: {} }] },
                                             { text: "done" }
                                           ])
    agent = Mistri::Agent.new(provider:, tools: [tool], before_tool: peek)

    agent.run("go")

    assert_equal [agent.session.id], seen
  end
end
