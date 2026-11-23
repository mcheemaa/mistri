# frozen_string_literal: true

require_relative "test_helper"

# A tool result is bounded where it is stored, and the results that answer one
# assistant message share a limit, so one turn always fits in the window.
class TestResultLimit < Minitest::Test
  ROW = "order 1001 shipped to a customer\n"
  ROWS = ROW * 10_000

  def test_a_large_result_is_stored_as_its_start_with_its_true_size
    seen = nil
    events = []
    agent = agent_for([{ name: "export" }], after_tool: lambda { |_call, result, _context|
      seen = result.bytesize
      nil
    })

    agent.run("go") { |event| events << event }
    stored = agent.session.messages.find(&:tool?)

    assert_equal ROWS.bytesize, seen, "the hook reads the whole result"
    assert_operator stored.text.bytesize, :<=, Mistri::ResultLimit::DEFAULT_BYTES
    assert(stored.text.lines[0..-2].all?(ROW), "the start is whole lines")
    assert_match(/was 330000 bytes in 10000 lines.*not kept.*call it again/, stored.text.lines.last)
    assert_equal({ "bytes" => 330_000, "lines" => 10_000 }, stored.cut)
    assert_equal stored.cut, Mistri::Message.from_h(stored.to_h).cut
    assert_equal stored.text, events.find { |event| event.type == :tool_result }.content
  end

  def test_the_results_of_one_turn_share_its_bytes
    calls = Array.new(20) { |page| { name: "export", arguments: { "page" => page } } }
    agent = agent_for(calls + [{ name: "count" }])

    agent.run("go")
    results = agent.session.messages.select(&:tool?)

    assert_operator results.sum { |result| result.text.bytesize }, :<=,
                    Mistri::ResultLimit::DEFAULT_TURN_BYTES
    assert_equal "10000 rows", results.last.text, "a small result stays whole"
    assert_nil results.last.cut
    assert_equal 1, results.first(20).map { |result| result.text.bytesize }.uniq.length
    assert_match(/share one limit.*fewer calls at a time/, results.first.text.lines.last)
  end

  def test_a_turn_of_many_results_leaves_each_its_floor
    calls = Array.new(150) { |page| { name: "export", arguments: { "page" => page } } }
    agent = agent_for(calls)

    agent.run("go")
    sizes = agent.session.messages.select(&:tool?).map { |result| result.text.bytesize }

    assert_operator sizes.min, :>, 1_900
    assert_operator sizes.max, :<=, Mistri::ResultLimit::SHARED_FLOOR_BYTES
  end

  def test_a_result_answered_after_an_approval_counts_what_the_turn_holds
    calls = Array.new(4) { |page| { name: "export", arguments: { "page" => page } } }
    agent = agent_for(calls + [{ name: "export_all" }])
    pending = agent.run("go").pending.first
    agent.session.approve(pending.id)

    agent.resume
    approved = agent.session.messages.select(&:tool?).last

    assert_equal "export_all", approved.tool_name
    assert_operator approved.text.bytesize, :<=, Mistri::ResultLimit::SHARED_FLOOR_BYTES
    assert_equal 330_000, approved.cut["bytes"]
  end

  def test_a_hook_cannot_take_the_turn_over_its_bytes
    calls = Array.new(6) { { name: "count" } }
    agent = agent_for(calls, after_tool: ->(_call, _result, _context) { ROWS })

    agent.run("go")
    stored = agent.session.messages.select(&:tool?).sum { |result| result.text.bytesize }

    assert_operator stored, :<=,
                    Mistri::ResultLimit::DEFAULT_TURN_BYTES + (2 * Mistri::ResultLimit::SHARED_FLOOR_BYTES)
  end

  def test_a_limit_takes_positive_whole_numbers_and_only_a_tool_message_is_cut
    assert_raises(ArgumentError) { Mistri::ResultLimit.new(bytes: 0) }
    assert_raises(ArgumentError) { Mistri::ResultLimit.new(turn_bytes: 1.5) }
    assert_raises(ArgumentError) { Mistri::Message.new(role: :user, content: "x", cut: {}) }
  end

  def test_a_result_that_a_hook_returns_as_rows_is_cut_like_any_other
    rows = Array.new(5_000) { |id| { "id" => id, "note" => "x" * 60 } }

    [rows, { "rows" => rows }].each do |returned|
      agent = agent_for([{ name: "count" }], after_tool: ->(_call, _result, _context) { returned })
      agent.run("go")
      stored = agent.session.messages.find(&:tool?)

      assert_operator stored.content.sum { |block| block.text.bytesize }, :<=, 50_000
      assert_operator stored.cut["bytes"], :>, 300_000
    end
  end

  def test_a_result_that_a_hook_makes_smaller_leaves_its_room_to_the_results_after_it
    orders = Mistri::Tool.define("orders", "Lists orders.") { ROW * 1_300 }
    export = Mistri::Tool.define("export", "Exports rows.") { ROWS }
    calls = Array.new(4) { { name: "export" } } + Array.new(4) { { name: "orders" } }
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    brief = ->(call, _result, _context) { "330000 bytes kept elsewhere" if call.name == "export" }
    agent = Mistri::Agent.new(provider:, tools: [export, orders], after_tool: brief)

    agent.run("go")
    results = agent.session.messages.select(&:tool?)

    assert_equal [ROW * 1_300] * 4, results.last(4).map(&:text)
    assert(results.none?(&:cut))
  end

  def test_a_tool_is_told_the_bytes_the_result_of_its_call_keeps
    told = {}
    tool = lambda do |name, **options|
      Mistri::Tool.define(name, "Reports.", **options) do |_arguments, context|
        told[name] = context.result_limit
        "ok"
      end
    end
    calls = [{ name: "paged" }] + Array.new(9) { { name: "plain" } }
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])

    Mistri::Agent.new(provider:, tools: [tool.call("paged", result_limit: 5_000),
                                         tool.call("plain")]).run("go")

    assert_equal({ "paged" => 5_000, "plain" => 20_000 }, told)
  end

  def test_a_tools_own_limit_is_a_positive_number_of_bytes
    [false, 0, "200000", 1.5].each do |limit|
      error = assert_raises(ArgumentError) do
        Mistri::Tool.define("export", "Exports rows.", result_limit: limit) { "rows" }
      end
      assert_equal "result_limit must be a positive Integer of bytes", error.message
    end
  end

  def test_a_result_of_text_blocks_keeps_its_first_blocks
    blocks = %w[a b c].map { |letter| Mistri::Content::Text.new(text: letter * 3_000) }
    limit = Mistri::ResultLimit.new(bytes: 4_500)

    kept, cut = limit.bound(blocks)

    assert_equal 9_000, cut["bytes"]
    assert_equal "a" * 3_000, kept[0].text
    assert_match(/\Ab+\z/, kept[1].text)
    assert_match(/\A\[This result was 9000 bytes/, kept[2].text)
    assert_equal 3, kept.length
  end

  def test_a_result_approved_where_no_limit_is_in_force_is_stored_whole
    agent = agent_for([{ name: "export_all" }], result_limit: false)
    pending = agent.run("go").pending.first
    agent.session.approve(pending.id)

    agent.resume

    assert_equal 330_000, agent.session.messages.select(&:tool?).last.text.bytesize
  end

  def test_false_stores_a_result_whole
    agent = agent_for([{ name: "export" }], result_limit: false)

    agent.run("go")
    stored = agent.session.messages.find(&:tool?)

    assert_equal ROWS, stored.text
    assert_nil stored.cut
  end

  def test_an_image_stays_and_no_character_is_split
    image = Mistri::Content::Image.from_bytes("png", mime_type: "image/png")
    shot = Mistri::Tool.define("shot", "Takes a picture.") do
      Mistri::ToolResult.new(content: [Mistri::Content::Text.new(text: "é" * 40_000), image])
    end
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: [{ name: "shot" }] },
                                                   { text: "done" }])
    agent = Mistri::Agent.new(provider:, tools: [shot])

    agent.run("go")
    stored = agent.session.messages.find(&:tool?)

    assert_includes stored.content, image
    assert_predicate stored.text, :valid_encoding?
    assert_operator stored.text.bytesize, :<=, Mistri::ResultLimit::DEFAULT_BYTES
    assert_equal 80_000, stored.cut["bytes"]
  end

  private

  def agent_for(calls, **)
    export = Mistri::Tool.define("export", "Exports rows.",
                                 schema: -> { integer :page, "Page" }) { ROWS }
    export_all = Mistri::Tool.define("export_all", "Exports every row.",
                                     needs_approval: true) { ROWS }
    count = Mistri::Tool.define("count", "Counts rows.") { "10000 rows" }
    provider = Mistri::Providers::Fake.new(turns: [{ tool_calls: calls }, { text: "done" }])
    Mistri::Agent.new(provider:, tools: [export, export_all, count], **)
  end
end
