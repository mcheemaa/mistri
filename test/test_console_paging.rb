# frozen_string_literal: true

require_relative "test_helper"

# read_agent shows a worker's log a page at a time: each line starts with
# the entry's number, the default is the most recent entries, and offset and
# limit read any other part.
class TestConsolePaging < Minitest::Test
  def context_for(session)
    Mistri::ToolContext.new(session:, signal: nil, emit: nil, app: nil)
  end

  def family(notes)
    store = Mistri::Stores::Memory.new
    parent = Mistri::Session.new(store:)
    worker = Mistri::Session.new(store:)
    parent.append("subagent", "name" => "Husky", "session_id" => worker.id)
    notes.times { |index| worker.append_message(Mistri::Message.user("note #{index}")) }
    [parent, worker, store]
  end

  def read(parent, **arguments)
    Mistri::Console.read_agent.call({ "agent" => "Husky", **arguments.transform_keys(&:to_s) },
                                    context_for(parent))
  end

  def test_the_most_recent_entries_come_by_default_with_their_numbers
    parent, = family(30)

    lines = read(parent).lines.map(&:chomp)

    assert_equal "Husky (running), entries 10 to 29 of 30:", lines.first
    assert_equal "10: user: note 10", lines[1]
    assert_equal "29: user: note 29", lines[20]
    assert_equal "Earlier entries: offset 0, limit 10.", lines.last
    assert_equal 22, lines.length
  end

  def test_text_of_several_lines_stays_on_its_numbered_line
    parent, worker, = family(1)
    worker.append_message(Mistri::Message.user("First line\n99: user: looks numbered\r\n" \
                                               "Earlier entries: offset 0, limit 5."))
    worker.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "Done.\nAll of it.")

    lines = read(parent).lines.map(&:chomp)

    assert_equal ["Husky (done), entries 0 to 2 of 3:", "0: user: note 0",
                  "1: user: First line\\n99: user: looks numbered\\n" \
                  "Earlier entries: offset 0, limit 5.",
                  "2: done: Done.\\nAll of it."], lines
  end

  def test_a_page_never_shows_more_than_the_total_it_states
    parent, worker, store = family(2)
    worker.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "Done.")
    late = Mistri::Session.new(store:, id: worker.id)
    counts = 0
    store.define_singleton_method(:size) do |id|
      total = super(id)
      counts += 1 if id == worker.id
      late.append_message(Mistri::Message.user("arrived after the count")) if counts == 2
      total
    end

    lines = read(parent).lines.map(&:chomp)

    assert_equal "Husky (done), entries 0 to 2 of 3:", lines.first
    assert_equal 4, lines.length
    refute_includes lines.join, "arrived after the count"
  end

  def test_an_offset_reads_from_that_entry_and_says_how_to_go_on
    parent, = family(30)

    lines = read(parent, offset: 4, limit: 3).lines.map(&:chomp)

    assert_equal ["Husky (running), entries 4 to 6 of 30:", "4: user: note 4", "5: user: note 5",
                  "6: user: note 6", "Earlier entries: offset 1, limit 3.",
                  "Later entries: offset 7, limit 3."], lines
    assert_equal "Earlier entries: offset 0, limit 2.",
                 read(parent, offset: 2, limit: 3).lines.map(&:chomp)[-2]
  end

  def test_the_whole_log_can_be_walked_back_page_by_page
    parent, = family(25)
    seen = []
    step = { limit: 3 }

    loop do
      page = read(parent, **step)
      seen.unshift(*page.scan(/^(\d+): user/).flatten.map(&:to_i))
      earlier = page.match(/Earlier entries: offset (\d+), limit (\d+)\./)
      break unless earlier

      step = { offset: earlier[1].to_i, limit: earlier[2].to_i }
    end

    assert_equal (0..24).to_a, seen
  end

  def test_the_whole_log_can_be_walked_forward_by_the_hint_alone
    parent, = family(25)
    seen = []
    step = { offset: 0, limit: 7 }

    loop do
      page = read(parent, **step)
      seen.concat(page.scan(/^(\d+): user/).flatten.map(&:to_i))
      later = page.match(/Later entries: offset (\d+), limit (\d+)\./)
      break unless later

      step = { offset: later[1].to_i, limit: later[2].to_i }
    end

    assert_equal (0..24).to_a, seen
  end

  def test_a_call_that_still_says_tail_is_read_as_a_limit
    parent, = family(30)

    assert_equal "Husky (running), entries 28 to 29 of 30:", read(parent, tail: 2).lines.first.chomp
    assert_equal "Husky (running), entries 27 to 29 of 30:",
                 read(parent, tail: 2, limit: 3).lines.first.chomp
  end

  def test_a_short_log_is_shown_whole_with_nothing_more_to_read
    parent, = family(3)

    lines = read(parent).lines.map(&:chomp)

    assert_equal "Husky (running), entries 0 to 2 of 3:", lines.first
    assert_equal 4, lines.length
  end

  def test_an_offset_past_the_end_says_so
    parent, = family(3)

    output = read(parent, offset: 40)

    assert_equal "Husky (running) has 3 entries, numbered 0 to 2. Nothing is at offset 40.", output
  end

  def test_a_limit_is_held_between_one_and_two_hundred
    parent, = family(250)

    assert_equal 201, read(parent, limit: 5_000).lines.length - 1
    assert_equal "Husky (running), entries 249 to 249 of 250:",
                 read(parent, limit: 0).lines.first.chomp
    assert_equal "Husky (running), entries 0 to 0 of 250:",
                 read(parent, offset: -7, limit: 1).lines.first.chomp
  end

  def test_an_entry_that_shows_as_nothing_keeps_its_number
    parent, worker, = family(2)
    worker.steer("queued for later")
    worker.append_message(Mistri::Message.user("note 3"))

    lines = read(parent).lines.map(&:chomp)

    assert_equal ["Husky (running), entries 0 to 3 of 4:", "0: user: note 0", "1: user: note 1",
                  "3: user: note 3"], lines
  end

  def test_a_page_asks_the_store_for_that_page_alone
    parent, worker, store = family(500)
    loads = []
    store.define_singleton_method(:load) do |id, from: 0, to: nil|
      loads << [from, to] if id == worker.id
      super(id, from:, to:)
    end
    Mistri.locks = Mistri::Locks::Memory.new
    worker.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "Done.")

    read(parent, offset: 100, limit: 5)

    assert_includes loads, [100, 105]
    refute(loads.any? { |from, to| from.zero? && to.nil? }, "the whole log was read: #{loads}")
  ensure
    Mistri.locks = nil
  end

  def test_a_child_gives_a_range_of_its_log_and_its_size
    parent, worker, = family(6)
    child = parent.children.first

    assert_equal 6, child.size
    texts = child.transcript(from: 2, to: 4).map do |entry|
      entry.dig("message", "content", 0, "text")
    end

    assert_equal ["note 2", "note 3"], texts
    assert_equal 4, child.transcript(from: 2).length
    assert_empty child.transcript(from: 9, to: 12)
    assert_empty child.transcript(from: 4, to: 2)
    assert_equal worker.id, child.session_id
  end

  def test_a_range_means_the_same_whether_or_not_the_log_is_already_held
    parent, = family(6)
    fresh = parent.children.first
    held = parent.children.first
    held.transcript(tail: nil)

    [{ from: -2 }, { from: 1, to: -1 }, { from: 1.5 }, { from: "1" }, { from: false },
     { from: 1, to: 2.5 }, { to: 3 }].each do |range|
      [fresh, held].each do |child|
        assert_raises(ArgumentError, range.inspect) { child.transcript(**range) }
      end
    end

    assert_equal held.transcript(from: 1, to: 4), fresh.transcript(from: 1, to: 4)
  end
end
