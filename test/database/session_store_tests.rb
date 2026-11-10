# frozen_string_literal: true

# What the Active Record session store promises on a real database. Each
# adapter suite includes this and names its model.
module SessionStoreTests
  def setup
    model.delete_all
    @store = Mistri::Stores::ActiveRecord.new(model)
  end

  def test_appends_take_positions_in_order_without_a_gap
    5.times { |n| @store.append("s", { "n" => n }) }

    assert_equal [1, 2, 3, 4, 5], model.where(session_id: "s").order(:position).pluck(:position)
    assert_equal([0, 1, 2, 3, 4], @store.load("s").map { |entry| entry["n"] })
  end

  def test_a_read_from_a_position_is_the_whole_log_without_its_start
    5.times { |n| @store.append("s", { "n" => n }) }
    @store.append("other", { "n" => 99 })
    whole = @store.load("s")

    (0..6).each { |from| assert_equal whole.drop(from), @store.load("s", from:) }
  end

  def test_a_read_from_a_position_is_one_query_bounded_by_position
    5.times { |n| @store.append("s", { "n" => n }) }

    queries = selects { @store.load("s", from: 3) }

    assert_equal 1, queries.length
    assert_match(/position\W+>=/, queries.first)
  end

  def test_a_session_with_a_deleted_row_is_refused
    3.times { |n| @store.append("s", { "n" => n }) }
    model.where(session_id: "s", position: 2).delete_all

    assert_raises(Mistri::ConfigurationError) { @store.load("s") }
  end

  private

  def selects(&)
    queries = []
    record = lambda do |*, payload|
      queries << payload[:sql] if payload[:sql].start_with?("SELECT") && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(record, "sql.active_record", &)
    queries
  end
end
