# frozen_string_literal: true

require_relative "test_helper"

# Random valid sessions, grown one step at a time. After every step a session
# must answer what the whole log answers, however its window was found:
# scanned back from the end, held by the writer, or held by a reader that only
# ever reads. The whole log is read with the carried state taken out, so no
# compaction bounds it.
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
    last_compaction: ->(session) { session.last_compaction&.except("carried") },
    compaction_failures: lambda(&:compaction_failures),
    children: ->(session) { session.children.map { |child| [child.name, child.session_id] } }
  }.freeze

  # A store with only append and load(id), whose compactions carry nothing.
  class Whole
    def initialize(store) = @store = store

    def append(id, entry) = @store.append(id, entry)

    def load(id) = @store.load(id).map { |entry| entry.except("carried") }
  end

  def test_every_reader_answers_what_the_whole_log_answers
    SEEDS.times do |seed|
      @random = Random.new(seed)
      @store = Mistri::Stores::Memory.new
      @held = Mistri::Session.new(store: @store, id: "s")
      @reader = Mistri::Session.new(store: @store, id: "s")
      @count = 0
      @unreported = []
      @settled = []
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
      assert_equal [expected], [read.call(@held)], "#{name} held by the writer differs at #{at}"
      assert_equal [expected], [read.call(@reader)], "#{name} held by a reader differs at #{at}"
    end
    compare_reports(scanned, at)
  end

  def compare_reports(session, at)
    @store.load("s").select { |entry| entry["type"] == "subagent_report" }.each do |report|
      again = session.deliver_report(name: report["name"], session_id: report["session_id"],
                                     status: report["status"], text: report["report"])

      refute again, "a report was delivered twice at #{at}"
    end
  end

  def take_step
    @count += 1
    steps = parked ? %i[steer spawn report compact late decide decide] : open_steps
    send(steps.sample(random: @random))
  end

  def open_steps
    %i[exchange exchange exchange tools tools steer spawn report crash park legacy legacy
       late by_hand compact compact compact]
  end

  def parked = @held.open_approvals.first

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

  def park = agent({ tool_calls: [{ name: "gated", arguments: {} }] }).run("ask first #{@count}")

  def decide
    open = parked
    id = open[:call].id
    unless open[:decision]
      @random.rand(2).zero? ? @held.approve(id) : @held.deny(id)
    end
    agent({ text: "after the decision #{@count}" }).resume
    @settled << id
  end

  # A turn as releases before 0.6.0 wrote it: a call_N id that repeats, here
  # with an approval, settled or left with only its decision.
  def legacy
    call = Mistri::ToolCall.new(id: "call_#{@random.rand(1..2)}", name: "gated", arguments: {})
    @held.append_message(Mistri::Message.user("legacy #{@count}"))
    @held.append_message(Mistri::Message.assistant(tool_calls: [call], stop_reason: :tool_use,
                                                   provider: :gemini))
    @held.append("approval_request", "call" => call.to_h)
    @held.append("approval_decision", "call_id" => call.id, "approved" => true)
    return if @random.rand(3).zero?

    @held.append_message(Mistri::Message.tool(content: "ran", tool_call_id: call.id,
                                              tool_name: "gated"))
    @settled << call.id
  end

  # A decision that lost its race and is written long after its call settled.
  def late
    id = @settled.sample(random: @random)
    @held.append("approval_decision", "call_id" => id, "approved" => false) if id
  end

  # A compaction as an older release or a host writes it: it carries nothing.
  def by_hand
    return unless @held.pending_inbox.empty?

    start = @held.replay.reverse_each.find { |message, index| index && message.user? }&.last
    floor = @held.last_compaction&.fetch("kept_from") || 0
    return unless start && start > floor

    @held.append("compaction", "summary" => "By hand #{@count}.", "kept_from" => start)
  end

  def compact
    summarizer = Mistri::Providers::Fake.new(turns: [{ text: "Summary #{@count}." }])
    settings = Mistri::Compaction.new(keep_recent: @random.rand(1..40))
    Mistri::Compactor.call(session: @held, provider: summarizer, settings:)
  end
end
