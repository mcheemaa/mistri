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

  def test_size_is_the_number_of_entries_appended
    assert_equal 0, @store.size("s")
    5.times { |n| @store.append("s", { "n" => n }) }
    @store.append("other", { "n" => 99 })

    assert_equal 5, @store.size("s")
  end

  def test_a_read_between_two_positions_is_one_query_bounded_on_both_sides
    6.times { |n| @store.append("s", { "n" => n }) }

    numbers = nil
    queries = selects { numbers = @store.load("s", from: 2, to: 5).map { |entry| entry["n"] } }

    assert_equal [2, 3, 4], numbers
    assert_equal 1, queries.length
    assert_match(/BETWEEN|<=/i, queries.first)
  end

  def test_a_new_session_reads_its_window_and_not_the_whole_log
    writer = Mistri::Session.new(store: @store, id: "s")
    150.times { |n| writer.append_message(Mistri::Message.user("old #{n}")) }
    writer.checkpoint(summary: "Earlier.", kept_from: 148)
    writer.append_message(Mistri::Message.user("new"))

    texts = nil
    queries = selects { texts = Mistri::Session.new(store: @store, id: "s").messages.map(&:text) }

    assert_equal ["old 148", "old 149", "new"], texts.drop(1)
    assert_equal 2, queries.length
    assert_match(/BETWEEN|<=/i, queries.last)
  end

  def test_a_finished_workers_status_is_two_queries_for_one_row
    worker = Mistri::Session.new(store: @store, id: "s")
    150.times { |n| worker.append_message(Mistri::Message.user("step #{n}")) }
    worker.append(Mistri::Child::TERMINAL, "status" => "done", "report" => "Done.")

    status = nil
    queries = selects { status = Mistri::Child.new(name: "Magpie", session_id: "s", store: @store).status }

    assert_equal :done, status
    assert_equal 2, queries.length
    assert_match(/position\W+ = /, queries.last)
  end

  def test_a_session_with_a_deleted_row_is_refused
    3.times { |n| @store.append("s", { "n" => n }) }
    model.where(session_id: "s", position: 2).delete_all

    assert_raises(Mistri::ConfigurationError) { @store.load("s") }
  end

  def test_a_session_read_does_not_keep_a_connection_checked_out
    session = Mistri::Session.new(store: @store)
    session.append_message(Mistri::Message.user("hello"))
    model.connection_pool.release_connection

    session.messages
    session.messages

    refute_predicate model.connection_pool, :active_connection?
  end

  def test_a_session_does_not_keep_a_decision_that_was_rolled_back
    session = session_with_a_parked_approval

    model.transaction do
      session.approve("call_a")

      assert session.open_approvals.first[:decision]["approved"]
      raise ActiveRecord::Rollback
    end

    assert_nil session.open_approvals.first[:decision]
    session.deny("call_a")

    refute session.open_approvals.first[:decision]["approved"]
  end

  def test_a_transaction_reads_its_own_snapshot_not_what_the_session_holds
    session = session_with_a_parked_approval
    pinned = Queue.new
    decided = Queue.new
    reader = Thread.new do
      model.transaction(isolation: :repeatable_read) do
        model.where(session_id: session.id).count
        pinned << true
        raise "the decision never arrived" unless decided.pop(timeout: 10)

        session.open_approvals.first[:decision]
      end
    end

    assert pinned.pop(timeout: 10), "the reader never pinned its snapshot"
    session.approve("call_a")

    assert session.open_approvals.first[:decision]["approved"]
    decided << true

    assert_nil reader.value
  ensure
    decided << true
    reader&.join
  end

  def test_another_connection_sees_an_append_once_it_commits
    @store.append("s", { "n" => 0 })
    appended = Queue.new
    commit = Queue.new
    writer = Thread.new do
      model.transaction do
        @store.append("s", { "n" => 1 })
        appended << true
        raise "the commit signal never arrived" unless commit.pop(timeout: 10)
      end
    end

    assert appended.pop(timeout: 10), "the writer never appended"
    assert_equal 1, @store.load("s").length
    commit << true
    writer.join

    assert_equal([0, 1], @store.load("s").map { |entry| entry["n"] })
  ensure
    commit << true
    writer&.join
  end

  private

  def session_with_a_parked_approval
    session = Mistri::Session.new(store: @store)
    call = Mistri::ToolCall.new(id: "call_a", name: "send", arguments: { "to" => "ops" })
    session.append_message(Mistri::Message.user("send it"))
    session.append_message(Mistri::Message.assistant(content: [call], stop_reason: :tool_use))
    session.append("approval_request", "call" => JSON.parse(JSON.generate(call.to_h)))
    session.open_approvals
    session
  end

  def selects(&)
    queries = []
    record = lambda do |*, payload|
      queries << payload[:sql] if payload[:sql].start_with?("SELECT") && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(record, "sql.active_record", &)
    queries
  end
end
