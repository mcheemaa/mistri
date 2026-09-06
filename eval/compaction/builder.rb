# frozen_string_literal: true

module CompactionEval
  # Turns a scenario into a session: fact turns land where the scenario put
  # them, filler turns pad the rest to the target size, and the last turns
  # stay outside the cut so every fact is summarized, not kept. Deterministic
  # for a seed, so two runs compare the same history.
  class Builder
    TURNS = { "S" => 11, "M" => 55, "L" => 165 }.freeze
    FOLD_TURNS = 12
    TAIL_TURNS = 2
    # About 725 tokens per turn, so the kept tail is two turns and change.
    KEEP_RECENT = 1_500
    SHALLOW_LOG = 1_700
    DEEP_LOG = 6_000

    attr_reader :scenario, :size, :fact_entries

    def initialize(scenario, size:, seed:)
      raise ArgumentError, "size must be one of #{TURNS.keys.join(", ")}" unless TURNS.key?(size)

      @scenario = scenario
      @size = size
      @rng = Random.new(seed)
      @fact_entries = {}
      @turn_index = 0
    end

    def build(session = Mistri::Session.new(store: Mistri::Stores::Memory.new))
      append_segment(session, 0)
      session
    end

    # Segment turns for a fold: the scenario's later facts arrive after a
    # checkpoint exists, so the next compaction folds them into it.
    def append_segment(session, index)
      facts = scenario.segments.fetch(index)
      turns = index.zero? ? TURNS.fetch(size) : FOLD_TURNS
      placed = place(facts, turns)
      turns.times { |turn| append_turn(session, index, turn, placed.fetch(turn, [])) }
      session
    end

    # A session holding exactly what the real cut keeps: the floor a summary
    # must beat. A throwaway compaction with a placeholder summary finds the
    # boundary the same way the measured run does.
    def tail_session(session)
      probe = Mistri::Session.new(store: Mistri::Stores::Memory.new)
      session.entries.each { |entry| probe.append(entry["type"], entry.except("type", "at")) }
      placeholder = Mistri::Providers::Fake.new(turns: [{ text: "placeholder summary" }])
      Mistri::Compactor.call(session: probe, provider: placeholder,
                             settings: Mistri::Compaction.new(keep_recent: KEEP_RECENT))
      tail = Mistri::Session.new(store: Mistri::Stores::Memory.new)
      probe.messages.drop(1).each { |message| tail.append_message(message) }
      tail
    end

    # Facts whose turn survived the cut instead of being summarized.
    def facts_kept(kept_from)
      fact_entries.select { |_, entry| entry >= kept_from }.keys
    end

    private

    def place(facts, turns)
      usable = turns - TAIL_TURNS
      taken = Hash.new { |hash, key| hash[key] = [] }
      facts.sort_by(&:at).each do |fact|
        turn = [(fact.at * (usable - 1)).round, usable - 1].min
        while turn < usable - 1 && taken[turn].any? { |other| other.carrier == fact.carrier }
          turn += 1
        end
        taken[turn] << fact
      end
      taken
    end

    def append_turn(session, segment, turn, facts)
      filler = scenario.filler.call(@turn_index, @rng)
      tool_borne = facts.any? { |fact| %i[tool tool_deep].include?(fact.carrier) }
      filler = Filler.fail(filler, @rng) if Filler.fails?(@turn_index) && !tool_borne
      @turn_index += 1
      first_entry = session.entries.length
      call = Mistri::ToolCall.new(id: "call_#{segment}_#{turn}", name: filler.fetch(:tool),
                                  arguments: filler.fetch(:arguments))
      session.append_message(Mistri::Message.user(carried(facts, :user) || filler.fetch(:ask)))
      session.append_message(Mistri::Message.assistant(content: filler.fetch(:doing),
                                                       tool_calls: [call], stop_reason: :tool_use))
      session.append_message(Mistri::Message.tool(content: tool_text(facts, filler),
                                                  tool_call_id: call.id, tool_name: call.name))
      session.append_message(Mistri::Message.assistant(
                               content: carried(facts, :assistant) || filler.fetch(:done),
                               stop_reason: :stop
                             ))
      facts.each { |fact| @fact_entries[fact.key] = first_entry }
    end

    def carried(facts, carrier)
      texts = facts.select { |fact| fact.carrier == carrier }.map(&:text)
      texts.empty? ? nil : texts.join(" ")
    end

    # A shallow fact leads the result, inside what the summarizer sees; a deep
    # fact sits in the middle of a long result, inside what it truncates.
    def tool_text(facts, filler)
      deep = carried(facts, :tool_deep)
      shallow = carried(facts, :tool)
      body = filler.fetch(:log).call(deep ? DEEP_LOG : SHALLOW_LOG)
      body = "#{shallow}\n#{body}" if shallow
      body = "#{body[0, DEEP_LOG / 2]}\n#{deep}\n#{body[(DEEP_LOG / 2)..]}" if deep
      body
    end
  end
end
