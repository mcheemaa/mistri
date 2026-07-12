# frozen_string_literal: true

require_relative "../test_helper"

url = ENV.fetch("MISTRI_MYSQL_URL", nil)
abort "MISTRI_MYSQL_URL is required for the InnoDB workspace suite" if url.to_s.empty?

require "active_record"
require "mysql2"
require_relative "../../lib/mistri/workspace/active_record"

ActiveRecord::Base.establish_connection(url)
connection = ActiveRecord::Base.connection
connection.create_table(:mistri_atomic_documents, force: true, options: "ENGINE=InnoDB") do |t|
  t.string :tenant_id, null: false, limit: 64
  t.string :path, null: false, limit: 512
  t.text :content, size: :medium, null: false
end
connection.add_index(
  :mistri_atomic_documents,
  %i[tenant_id path],
  unique: true,
  name: "index_mistri_atomic_documents_on_scope_and_path"
)
connection.create_table(:mistri_non_atomic_documents, force: true, options: "ENGINE=MyISAM") do |t|
  t.string :tenant_id, null: false, limit: 64
  t.string :path, null: false, limit: 128
  t.text :content, null: false
end
connection.add_index(
  :mistri_non_atomic_documents,
  %i[tenant_id path],
  unique: true,
  name: "index_mistri_non_atomic_documents_on_scope_and_path"
)

# A real InnoDB row with opt-in callback barriers for deterministic races.
class MysqlAtomicDocument < ActiveRecord::Base
  self.table_name = "mistri_atomic_documents"

  class << self
    attr_accessor :create_barrier, :save_failure
  end

  before_create do
    barrier = self.class.create_barrier
    if barrier
      barrier.fetch(:arrivals) << true
      barrier.fetch(:releases).pop
    end
  end

  before_save do
    raise self.class.save_failure if self.class.save_failure
  end
end

# A real non-transactional table proves that an adapter name alone is not a
# sufficient atomicity claim.
class MysqlNonAtomicDocument < ActiveRecord::Base
  self.table_name = "mistri_non_atomic_documents"
end

# Forces two edit calls to take their initial snapshots before either CAS.
class MysqlSnapshotBarrier
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

# Injects one committed database write between an edit snapshot and its first
# conditional write, without changing the model-facing tool lifecycle.
class MysqlConflictOnce
  attr_reader :comparisons

  def initialize(workspace, &inject)
    @workspace = workspace
    @inject = inject
    @comparisons = 0
  end

  def atomic_writes? = true
  def snapshot(path) = @workspace.snapshot(path)
  def read(path) = @workspace.read(path)

  def compare_and_write(...)
    @comparisons += 1
    @inject.call if @comparisons == 1
    @workspace.compare_and_write(...)
  end
end

# The real database proof for scoped row locks and unique create CAS.
class TestWorkspaceMysql < Minitest::Test
  def setup
    MysqlAtomicDocument.delete_all
    MysqlAtomicDocument.create_barrier = nil
    MysqlAtomicDocument.save_failure = nil
  end

  def test_table_is_innodb_and_needs_no_lock_version
    status = ActiveRecord::Base.connection.exec_query(
      "SHOW TABLE STATUS LIKE 'mistri_atomic_documents'"
    ).first

    assert_equal "InnoDB", status.fetch("Engine")
    assert_match(/\A8\.4\./, ActiveRecord::Base.connection.select_value("SELECT VERSION()"))
    column = MysqlAtomicDocument.columns_hash.fetch("content")

    assert_equal "mediumtext", column.sql_type
    refute_includes MysqlAtomicDocument.column_names, "lock_version"
  end

  def test_a_myisam_table_does_not_advertise_atomic_writes
    workspace = Mistri::Workspace::ActiveRecord.new(
      MysqlNonAtomicDocument, scope: { tenant_id: "tenant-a" }
    )

    refute_predicate workspace, :atomic_writes?
    error = assert_raises(Mistri::ConfigurationError) { workspace.snapshot("page.html") }

    assert_match(/InnoDB/, error.message)
  end

  def test_atomic_operations_reject_an_external_transaction
    workspace = build_workspace("tenant-a", page)

    error = MysqlAtomicDocument.transaction do
      assert_raises(Mistri::ConfigurationError) { workspace.snapshot("page.html") }
    end

    assert_match(/cannot join an open transaction/, error.message)
  end

  def test_single_column_workspace_rebases_a_real_edit
    record = MysqlAtomicDocument.create!(
      tenant_id: "tenant-a", path: "page.html", content: page
    )
    base = build_single_workspace(record)
    workspace = MysqlConflictOnce.new(base) do
      MysqlAtomicDocument.where(id: record.id).update_all(
        content: page.sub("</main>", "  <aside>Human</aside>\n</main>")
      )
    end

    result = Mistri::Tools.edit_file(workspace).call(headline_edit("Agent"))
    final = workspace.read("page.html")

    assert_equal "Replaced 1 occurrence(s) in page.html", result
    assert_equal 2, workspace.comparisons
    assert_includes final, "<h1>Agent</h1>"
    assert_includes final, "<aside>Human</aside>"
  end

  def test_single_column_recipe_rejects_an_outer_transaction
    record = MysqlAtomicDocument.create!(
      tenant_id: "tenant-a", path: "page.html", content: page
    )
    workspace = build_single_workspace(record)
    tool = Mistri::Tools.edit_file(workspace)

    error = MysqlAtomicDocument.transaction do
      assert_raises(Mistri::ConfigurationError) { tool.call(headline_edit("Agent")) }
    end

    assert_match(/outside a transaction/, error.message)
    assert_equal page, record.reload.content
  end

  def test_a_stale_existing_row_write_is_rejected
    workspace = build_workspace("tenant-a", page)
    stale = workspace.snapshot("page.html")
    MysqlAtomicDocument.find_by!(tenant_id: "tenant-a", path: "page.html")
                       .update!(content: page.sub("Old", "Human"))

    error = assert_raises(Mistri::WorkspaceConflictError) do
      workspace.compare_and_write(
        "page.html", page.sub("Old", "Agent"), expected_revision: stale.revision
      )
    end

    assert_equal "page.html", error.path
    assert_includes workspace.read("page.html"), "<h1>Human</h1>"
  end

  def test_parallel_unrelated_edits_both_survive
    barrier = MysqlSnapshotBarrier.new(build_workspace("tenant-a", page))
    edits = [headline_edit("Agent"), paragraph_edit("Updated")]
    results = run_parallel_edits(barrier, edits)
    final = barrier.read("page.html")
    successes = results.count { |result| result.is_a?(String) }

    assert_equal 2, successes
    assert_includes final, "<h1>Agent</h1>"
    assert_includes final, "<p>Updated</p>"
  end

  def test_parallel_same_target_edits_have_one_winner
    barrier = MysqlSnapshotBarrier.new(build_workspace("tenant-a", page))
    results = run_parallel_edits(
      barrier, [headline_edit("First"), headline_edit("Second")]
    )
    final = barrier.read("page.html")
    failures = results.count do |result|
      result.is_a?(Mistri::ToolResult) && result.error?
    end
    successes = results.count { |result| result.is_a?(String) }
    winners = %w[First Second].count do |value|
      final.include?("<h1>#{value}</h1>")
    end

    assert_equal 1, successes
    assert_equal 1, failures
    assert_equal 1, winners
    assert_includes final, "<p>Old copy</p>"
  end

  def test_parallel_create_only_writes_leave_one_row
    workspace = Mistri::Workspace::ActiveRecord.new(
      MysqlAtomicDocument, scope: { tenant_id: "tenant-a" }
    )
    barrier = { arrivals: Queue.new, releases: Queue.new }
    MysqlAtomicDocument.create_barrier = barrier
    threads = %w[first second].map do |content|
      Thread.new do
        workspace.compare_and_write("new.html", content, expected_revision: nil)
      rescue Mistri::WorkspaceConflictError => e
        e
      end
    end
    2.times { barrier.fetch(:arrivals).pop }
    2.times { barrier.fetch(:releases) << true }
    results = threads.map(&:value)
    successes = results.count do |result|
      result.is_a?(Mistri::Workspace::Snapshot)
    end
    conflicts = results.count do |result|
      result.is_a?(Mistri::WorkspaceConflictError)
    end

    assert_equal 1, successes
    assert_equal 1, conflicts
    assert_equal 1, MysqlAtomicDocument.where(
      tenant_id: "tenant-a", path: "new.html"
    ).count
  ensure
    2.times { barrier&.fetch(:releases, nil)&.push(true) }
    threads&.each(&:join)
  end

  def test_create_returns_the_bytes_persisted_by_a_database_trigger
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TRIGGER normalize_mistri_content
      BEFORE INSERT ON mistri_atomic_documents
      FOR EACH ROW SET NEW.content = CONCAT(NEW.content, '!')
    SQL
    workspace = Mistri::Workspace::ActiveRecord.new(
      MysqlAtomicDocument, scope: { tenant_id: "tenant-a" }
    )

    created = workspace.compare_and_write("new.html", "new", expected_revision: nil)
    persisted = workspace.snapshot("new.html")

    assert_equal "new!", created.content
    assert_equal persisted, created
  ensure
    ActiveRecord::Base.connection.execute("DROP TRIGGER IF EXISTS normalize_mistri_content")
  end

  def test_edit_reports_when_storage_rejects_the_requested_bytes
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TRIGGER reject_mistri_content_update
      BEFORE UPDATE ON mistri_atomic_documents
      FOR EACH ROW SET NEW.content = OLD.content
    SQL
    workspace = build_workspace("tenant-a", page)

    result = Mistri::Tools.edit_file(workspace).call(headline_edit("Agent"))

    assert_predicate result, :error?
    assert_match(/write .* committed, but storage transformed/, result.content)
    assert_match(/read_file/, result.content)
    assert_equal page, workspace.read("page.html")
  ensure
    ActiveRecord::Base.connection.execute(
      "DROP TRIGGER IF EXISTS reject_mistri_content_update"
    )
  end

  def test_create_rolls_back_when_a_trigger_changes_document_identity
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TRIGGER move_mistri_document
      BEFORE INSERT ON mistri_atomic_documents
      FOR EACH ROW SET NEW.tenant_id = CONCAT(NEW.tenant_id, '-moved')
    SQL
    workspace = Mistri::Workspace::ActiveRecord.new(
      MysqlAtomicDocument, scope: { tenant_id: "tenant-a" }
    )

    error = assert_raises(Mistri::SchemaError) do
      workspace.compare_and_write("new.html", "new", expected_revision: nil)
    end

    assert_match(/changed identity/, error.message)
    assert_equal 0, MysqlAtomicDocument.count
  ensure
    ActiveRecord::Base.connection.execute("DROP TRIGGER IF EXISTS move_mistri_document")
  end

  def test_identical_paths_are_isolated_by_scope
    first = build_workspace("tenant-a", "a")
    second = build_workspace("tenant-b", "b")
    before = first.snapshot("page.html")

    first.compare_and_write("page.html", "a2", expected_revision: before.revision)

    assert_equal "a2", first.read("page.html")
    assert_equal "b", second.read("page.html")
  end

  def test_callback_failures_are_not_mislabeled_as_conflicts
    workspace = build_workspace("tenant-a", page)
    before = workspace.snapshot("page.html")
    MysqlAtomicDocument.save_failure = IOError.new("host callback failed")

    error = assert_raises(IOError) do
      workspace.compare_and_write(
        "page.html", page.sub("Old", "Agent"), expected_revision: before.revision
      )
    end

    assert_equal "host callback failed", error.message
    assert_equal page, workspace.read("page.html")
  end

  def test_unrelated_record_not_unique_is_not_mislabeled
    workspace = Mistri::Workspace::ActiveRecord.new(
      MysqlAtomicDocument, scope: { tenant_id: "tenant-a" }
    )
    MysqlAtomicDocument.save_failure = ActiveRecord::RecordNotUnique.new("other index")

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      workspace.compare_and_write("new.html", "new", expected_revision: nil)
    end

    assert_equal "other index", error.message
  end

  private

  def build_workspace(tenant, content)
    MysqlAtomicDocument.create!(tenant_id: tenant, path: "page.html", content:)
    Mistri::Workspace::ActiveRecord.new(
      MysqlAtomicDocument, scope: { tenant_id: tenant }
    )
  end

  def build_single_workspace(record)
    Mistri::Workspace::Single.new(
      path: "page.html",
      read: -> { record.reload.content },
      write: ->(content) { record.update!(content:) },
      synchronize: lambda do |&operation|
        if record.class.connection.transaction_open?
          raise Mistri::ConfigurationError, "page editor must run outside a transaction"
        end

        record.with_lock(&operation)
      end
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
