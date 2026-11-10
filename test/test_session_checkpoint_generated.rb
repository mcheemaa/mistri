# frozen_string_literal: true

require_relative "test_helper"

# Random valid sessions, grown one step at a time. After every step a session
# must answer the same however its window was found: scanned back from the end,
# held and extended, or cut down from a whole read. What a checkpoint carries
# is checked against the whole log.
class TestSessionCheckpointGenerated < Minitest::Test
  SEEDS = 12
  STEPS = 60

  PING = Mistri::Tool.define("ping", "Ping.") { "pong" }
  GATED = Mistri::Tool.define("gated", "Needs a person.", needs_approval: true) { "ran" }

  READS = {
    messages: ->(session) { session.messages.map(&:to_h) },
    context_tokens: lambda(&:context_tokens),
    inbox: lambda(&:pending_inbox),
    approvals: lambda do |session|
      session.open_approvals.map { |open| [open[:call].to_h, open[:decision]] }
    end,
    last_compaction: lambda(&:last_compaction),
    compaction_failures: lambda(&:compaction_failures),
    tool_call_ids: ->(session) { session.tool_call_ids.to_a.sort },
    children: ->(session) { session.children.map { |child| [child.name, child.session_id] } }
  }.freeze

  # A store with only append and load(id), over another store's entries.
  class Whole
    def initialize(store) = @store = store

    def append(id, entry) = @store.append(id, entry)

    def load(id) = @store.load(id)
  end

  def test_every_reader_agrees_however_the_window_was_found
    SEEDS.times do |seed|
      @random = Random.new(seed)
      @store = Mistri::Stores::Memory.new
      @held = Mistri::Session.new(store: @store, id: "s")
      @count = 0
      @parked = nil
      @unreported = []
      STEPS.times do |step|
        take_step
        compare_readers("seed #{seed}, step #{step}")
      end
    end
  end

  private

  def compare_readers(at)
    scanned = Mistri::Session.new(store: @store, id: "s")
    whole = Mistri::Session.new(store: Whole.new(@store), id: "s")
    READS.each do |name, read|
      expected = read.call(whole)

      assert_equal [expected], [read.call(scanned)], "#{name} by a scan differs at #{at}"
      assert_equal [expected], [read.call(@held)], "#{name} by a held window differs at #{at}"
    end
    compare_carried(scanned, at)
  end

  def compare_carried(session, at)
    log = @store.load("s")
    links = log.select { |entry| entry["type"] == "subagent" }
               .map { |entry| entry.values_at("name", "session_id") }

    assert_equal links, READS.fetch(:children).call(session), "children differ at #{at}"
    log.select { |entry| entry["type"] == "subagent_report" }.each do |report|
      again = session.deliver_report(name: report["name"], session_id: report["session_id"],
                                     status: report["status"], text: report["report"])

      refute again, "a report was delivered twice at #{at}"
    end
  end

  def take_step
    @count += 1
    steps = @parked ? %i[steer spawn report compact decide decide] : open_steps
    send(steps.sample(random: @random))
  end

  def open_steps
    %i[exchange exchange exchange tools tools steer spawn report crash park compact compact]
  end

  def agent(*turns)
    Mistri::Agent.new(provider: Mistri::Providers::Fake.new(turns:), session: @held,
                      tools: [PING, GATED])
  end

  def exchange = agent({ text: "answer #{@count}" }).run("question #{@count}")

  def tools
    agent({ tool_calls: [{ name: "ping", arguments: {} }] }, { text: "done #{@count}" })
      .run("use the tool #{@count}")
  end

  def steer = @held.steer("steer #{@count}")

  def spawn
    @held.append("subagent", "name" => "Worker#{@count}", "session_id" => "child-#{@count}")
    @unreported << @count
  end

  def report
    number = @unreported.delete(@unreported.sample(random: @random))
    return unless number

    @held.deliver_report(name: "Worker#{number}", session_id: "child-#{number}",
                         status: "done", text: "Report #{number}.")
  end

  def crash
    call = Mistri::ToolCall.new(id: "lost-#{@count}", name: "ping", arguments: {})
    @held.append_message(Mistri::Message.user("crash #{@count}"))
    @held.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use))
  end

  def park
    result = agent({ tool_calls: [{ name: "gated", arguments: {} }] }).run("ask first #{@count}")
    @parked = result.pending.first.id
  end

  def decide
    @random.rand(2).zero? ? @held.approve(@parked) : @held.deny(@parked)
    agent({ text: "after the decision #{@count}" }).resume
    @parked = nil
  end

  def compact
    summarizer = Mistri::Providers::Fake.new(turns: [{ text: "Summary #{@count}." }])
    settings = Mistri::Compaction.new(keep_recent: @random.rand(1..40))
    Mistri::Compactor.call(session: @held, provider: summarizer, settings:)
  end
end
