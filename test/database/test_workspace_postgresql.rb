# frozen_string_literal: true

require_relative "../test_helper"

url = ENV.fetch("MISTRI_POSTGRES_URL", nil)
abort "MISTRI_POSTGRES_URL is required for the PostgreSQL workspace suite" if url.to_s.empty?

require "active_record"
require "pg"
require_relative "../../lib/mistri/workspace/active_record"

ActiveRecord::Base.establish_connection(url)
connection = ActiveRecord::Base.connection
connection.create_table(:mistri_postgresql_documents, force: true) do |t|
  t.string :tenant_id, null: false
  t.string :path, null: false
  t.text :content, null: false
end
connection.add_index(
  :mistri_postgresql_documents,
  %i[tenant_id path],
  unique: true,
  name: "index_mistri_postgresql_documents_on_scope_and_path"
)
connection.execute(<<~SQL)
  CREATE UNIQUE INDEX index_mistri_postgresql_documents_on_lower_path
  ON mistri_postgresql_documents (lower(path))
SQL

# A real PostgreSQL row used by the cross-process locking contract.
class PostgresqlAtomicDocument < ActiveRecord::Base
  self.table_name = "mistri_postgresql_documents"
end

# Forces two edit calls to take their initial snapshots before either CAS.
class PostgresqlSnapshotBarrier
  attr_reader :arrivals

  def initialize(workspace)
    @workspace = workspace
    @arrivals = Queue.new
    @releases = Queue.new
    @mutex = Mutex.new
    @snapshots = 0
  end

  def atomic_writes? = true

  def snapshot(path)
    snapshot = @workspace.snapshot(path)
    rendezvous = @mutex.synchronize do
      @snapshots += 1
      @snapshots <= 2
    end
    if rendezvous
      @arrivals << true
      @releases.pop
    end
    snapshot
  end

  def compare_and_write(...) = @workspace.compare_and_write(...)
  def read(path) = @workspace.read(path)

  def release_initial_snapshots
    2.times { @releases << true }
  end
end

# The real PostgreSQL proof for row locks, schema inspection, and create CAS.
class TestWorkspacePostgresql < Minitest::Test
  def setup
    PostgresqlAtomicDocument.delete_all
  end

  def test_expression_index_does_not_mask_the_valid_identity_index
    workspace = build_workspace("tenant-a", page)
    expression = ActiveRecord::Base.connection.indexes(
      PostgresqlAtomicDocument.table_name
    ).find { |index| index.name.include?("lower_path") }

    assert_instance_of String, expression.columns
    assert_predicate expression, :valid?
    assert_predicate workspace, :atomic_writes?
  end

  def test_atomic_operations_reject_an_external_transaction
    workspace = build_workspace("tenant-a", page)

    error = PostgresqlAtomicDocument.transaction do
      assert_raises(Mistri::ConfigurationError) { workspace.snapshot("page.html") }
    end

    assert_match(/cannot join an open transaction/, error.message)
  end

  def test_parallel_unrelated_edits_both_survive
    barrier = PostgresqlSnapshotBarrier.new(build_workspace("tenant-a", page))
    results = run_parallel_edits(
      barrier, [headline_edit("Agent"), paragraph_edit("Updated")]
    )
    final = barrier.read("page.html")
    successes = results.count { |result| result.is_a?(String) }

    assert_equal 2, successes
    assert_includes final, "<h1>Agent</h1>"
    assert_includes final, "<p>Updated</p>"
  end

  def test_parallel_same_target_edits_have_one_winner
    barrier = PostgresqlSnapshotBarrier.new(build_workspace("tenant-a", page))
    results = run_parallel_edits(
      barrier, [headline_edit("First"), headline_edit("Second")]
    )
    final = barrier.read("page.html")
    errors = results.count do |result|
      result.is_a?(Mistri::ToolResult) && result.error?
    end
    successes = results.count { |result| result.is_a?(String) }
    winners = %w[First Second].count { |value| final.include?("<h1>#{value}</h1>") }

    assert_equal 1, successes
    assert_equal 1, errors
    assert_equal 1, winners
  end

  def test_parallel_create_only_writes_leave_one_row
    workspace = Mistri::Workspace::ActiveRecord.new(
      PostgresqlAtomicDocument, scope: { tenant_id: "tenant-a" }
    )
    arrivals = Queue.new
    releases = Queue.new
    threads = %w[first second].map do |content|
      Thread.new do
        arrivals << true
        releases.pop
        workspace.compare_and_write("new.html", content, expected_revision: nil)
      rescue Mistri::WorkspaceConflictError => e
        e
      end
    end
    2.times { arrivals.pop }
    2.times { releases << true }
    results = threads.map(&:value)

    successes = results.count { |result| result.is_a?(Mistri::Workspace::Snapshot) }
    conflicts = results.count { |result| result.is_a?(Mistri::WorkspaceConflictError) }

    assert_equal 1, successes
    assert_equal 1, conflicts
    assert_equal 1, PostgresqlAtomicDocument.where(
      tenant_id: "tenant-a", path: "new.html"
    ).count
  ensure
    2.times { releases&.push(true) }
    threads&.each(&:join)
  end

  def test_update_returns_the_bytes_persisted_by_a_database_trigger
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE OR REPLACE FUNCTION mistri_append_content()
      RETURNS trigger AS $$
      BEGIN
        NEW.content := NEW.content || '!';
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    SQL
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TRIGGER append_mistri_content
      BEFORE UPDATE ON mistri_postgresql_documents
      FOR EACH ROW EXECUTE FUNCTION mistri_append_content()
    SQL
    workspace = build_workspace("tenant-a", "old")
    before = workspace.snapshot("page.html")

    committed = workspace.compare_and_write(
      "page.html", "requested", expected_revision: before.revision
    )

    assert_equal "requested!", committed.content
    assert_equal workspace.snapshot("page.html"), committed
  ensure
    ActiveRecord::Base.connection.execute(
      "DROP FUNCTION IF EXISTS mistri_append_content() CASCADE"
    )
  end

  private

  def build_workspace(tenant, content)
    PostgresqlAtomicDocument.create!(tenant_id: tenant, path: "page.html", content:)
    Mistri::Workspace::ActiveRecord.new(
      PostgresqlAtomicDocument, scope: { tenant_id: tenant }
    )
  end

  def run_parallel_edits(workspace, edits)
    threads = edits.map do |edit|
      Thread.new { Mistri::Tools.edit_file(workspace).call(edit) }
    end
    2.times { workspace.arrivals.pop }
    workspace.release_initial_snapshots
    threads.map(&:value)
  ensure
    workspace&.release_initial_snapshots if threads&.any?(&:alive?)
    threads&.each(&:join)
  end

  def page
    "<main>\n  <h1>Old</h1>\n  <p>Old copy</p>\n</main>\n"
  end

  def headline_edit(value)
    { "path" => "page.html", "old_string" => "<h1>Old</h1>",
      "new_string" => "<h1>#{value}</h1>" }
  end

  def paragraph_edit(value)
    { "path" => "page.html", "old_string" => "<p>Old copy</p>",
      "new_string" => "<p>#{value}</p>" }
  end
end
