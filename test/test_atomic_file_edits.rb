# frozen_string_literal: true

require_relative "test_helper"

# Atomic workspace edits retry only storage conflicts and reapply their content
# anchor to the latest complete document before committing.
class TestAtomicFileEdits < Minitest::Test
  # A versioned workspace with deterministic compare hooks for conflict tests.
  class ScriptedWorkspace
    attr_reader :snapshots, :comparisons

    def initialize(content, &before_compare)
      @content = content
      @before_compare = before_compare
      @snapshots = 0
      @comparisons = 0
      @mutex = Mutex.new
    end

    def atomic_writes? = true

    def snapshot(_path)
      @mutex.synchronize do
        @snapshots += 1
        @content && Mistri::Workspace::Snapshot.for(@content)
      end
    end

    def compare_and_write(path, content, expected_revision:)
      comparison = @mutex.synchronize do
        @comparisons += 1
      end
      @before_compare&.call(self, comparison)
      @mutex.synchronize do
        actual = @content && Mistri::Workspace::Snapshot.for(@content).revision
        unless actual == expected_revision
          raise Mistri::WorkspaceConflictError.new(
            path, expected_revision:, actual_revision: actual
          )
        end

        @content = content
        Mistri::Workspace::Snapshot.for(@content)
      end
    end

    def replace(content) = @content = content
    def content = @mutex.synchronize { @content&.dup }
  end

  # A committed-byte transform proves the tool does not claim an exact edit
  # when host storage persisted a different result.
  class TransformingWorkspace < ScriptedWorkspace
    def compare_and_write(path, content, expected_revision:)
      transformed = content.sub("<h1>Agent</h1>", "<h1>Stored</h1>")
      super(path, transformed, expected_revision:)
    end
  end

  # Database adapters may return the same bytes under a different encoding.
  class BinaryReadbackWorkspace < ScriptedWorkspace
    def compare_and_write(path, content, expected_revision:)
      super(path, content.b, expected_revision:)
    end
  end

  class InvalidSnapshotWorkspace < ScriptedWorkspace
    def snapshot(_path) = "not a snapshot"
  end

  class InvalidCommitWorkspace < ScriptedWorkspace
    def compare_and_write(*) = "not a snapshot"
  end

  # The first two snapshots rendezvous so two callers begin from one revision.
  class BarrierWorkspace
    attr_reader :arrivals

    def initialize(content)
      @workspace = Mistri::Workspace::Memory.new
      @workspace.write("page.html", content)
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

  # A legacy port records that edit_file kept the original read/write route.
  class LegacyWorkspace
    attr_reader :reads, :writes

    def initialize(content)
      @content = content
      @reads = 0
      @writes = 0
    end

    def read(_path)
      @reads += 1
      @content
    end

    def write(_path, content)
      @writes += 1
      @content = content
    end
  end

  def test_an_unrelated_conflict_rebases_and_preserves_both_changes
    workspace = ScriptedWorkspace.new(page) do |store, comparison|
      next unless comparison == 1

      store.replace(store.content.sub("</main>", "  <aside>Human</aside>\n</main>"))
    end

    result = tool(workspace).call(headline_edit("Agent"))

    assert_equal "Replaced 1 occurrence(s) in page.html", result
    assert_includes workspace.content, "<h1>Agent</h1>"
    assert_includes workspace.content, "<aside>Human</aside>"
    assert_equal 2, workspace.snapshots
    assert_equal 2, workspace.comparisons
  end

  def test_a_same_target_conflict_becomes_a_typed_edit_error
    workspace = ScriptedWorkspace.new(page) do |store, comparison|
      store.replace(store.content.sub("Old", "Human")) if comparison == 1
    end

    result = tool(workspace).call(headline_edit("Agent"))

    assert_predicate result, :error?
    assert_match(/old text was not found/, result.content)
    assert_includes workspace.content, "<h1>Human</h1>"
    assert_equal 2, workspace.snapshots
    assert_equal 1, workspace.comparisons
  end

  def test_deletion_during_a_conflict_becomes_a_missing_document_error
    workspace = ScriptedWorkspace.new(page) do |store, comparison|
      store.replace(nil) if comparison == 1
    end

    result = tool(workspace).call(headline_edit("Agent"))

    assert_predicate result, :error?
    assert_match(/No document at "page.html"/, result.content)
    assert_equal 2, workspace.snapshots
    assert_equal 1, workspace.comparisons
  end

  def test_sustained_contention_stops_at_the_exact_attempt_limit
    workspace = ScriptedWorkspace.new(page) do |store, _comparison|
      store.replace("#{store.content} ")
    end

    result = tool(workspace).call(headline_edit("Agent"))

    assert_predicate result, :error?
    assert_match(/changed; read it again/, result.content)
    assert_equal 3, workspace.snapshots
    assert_equal 3, workspace.comparisons
  end

  def test_non_conflict_storage_failures_are_not_retried
    workspace = ScriptedWorkspace.new(page) do |_store, _comparison|
      raise IOError, "database disconnected"
    end

    error = assert_raises(IOError) { tool(workspace).call(headline_edit("Agent")) }

    assert_equal "database disconnected", error.message
    assert_equal 1, workspace.snapshots
    assert_equal 1, workspace.comparisons
  end

  def test_an_atomic_workspace_must_return_a_snapshot_from_read
    workspace = InvalidSnapshotWorkspace.new(page)

    error = assert_raises(TypeError) { tool(workspace).call(headline_edit("Agent")) }

    assert_match(/workspace snapshot/, error.message)
  end

  def test_an_atomic_workspace_must_return_a_snapshot_from_commit
    workspace = InvalidCommitWorkspace.new(page)

    error = assert_raises(TypeError) { tool(workspace).call(headline_edit("Agent")) }

    assert_match(/compare_and_write/, error.message)
  end

  def test_a_transformed_commit_does_not_report_an_exact_replacement
    workspace = TransformingWorkspace.new(page)

    result = tool(workspace).call(headline_edit("Agent"))

    assert_predicate result, :error?
    assert_match(/write .* committed, but storage transformed/, result.content)
    assert_match(/read_file/, result.content)
    assert_includes workspace.content, "<h1>Stored</h1>"
  end

  def test_an_encoding_only_readback_does_not_become_a_false_failure
    content = page.sub("Old", "Café")
    workspace = BinaryReadbackWorkspace.new(content)

    result = tool(workspace).call(
      headline_edit("Agent").merge("old_string" => "<h1>Café</h1>")
    )

    assert_equal "Replaced 1 occurrence(s) in page.html", result
    assert_equal Encoding::BINARY, workspace.content.encoding
  end

  def test_parallel_unrelated_edits_both_survive
    workspace = BarrierWorkspace.new(page)
    edits = [headline_edit("Agent"), paragraph_edit("Updated")]
    threads = edits.map { |edit| Thread.new { tool(workspace).call(edit) } }
    2.times { workspace.arrivals.pop }
    workspace.release_initial_snapshots
    results = threads.map(&:value)
    successes = results.count { |result| result.is_a?(String) }

    assert_equal 2, successes
    assert_includes workspace.read("page.html"), "<h1>Agent</h1>"
    assert_includes workspace.read("page.html"), "<p>Updated</p>"
  ensure
    workspace&.release_initial_snapshots if threads&.any?(&:alive?)
    threads&.each(&:join)
  end

  def test_parallel_same_target_edits_have_one_complete_winner
    workspace = BarrierWorkspace.new(page)
    edits = [headline_edit("First"), headline_edit("Second")]
    threads = edits.map { |edit| Thread.new { tool(workspace).call(edit) } }
    2.times { workspace.arrivals.pop }
    workspace.release_initial_snapshots
    results = threads.map(&:value)
    final = workspace.read("page.html")
    successes = results.count { |result| result.is_a?(String) }

    assert_equal 1, successes
    errors = results.count do |result|
      result.is_a?(Mistri::ToolResult) && result.error?
    end

    assert_equal 1, errors
    winners = %w[First Second].count { |winner| final.include?("<h1>#{winner}</h1>") }

    assert_equal 1, winners
    assert_includes final, "<p>Old copy</p>"
  ensure
    workspace&.release_initial_snapshots if threads&.any?(&:alive?)
    threads&.each(&:join)
  end

  def test_internal_retries_remain_one_tool_lifecycle
    workspace = ScriptedWorkspace.new(page) do |store, comparison|
      if comparison == 1
        store.replace(store.content.sub("</main>", "  <aside>Human</aside>\n</main>"))
      end
    end
    provider = Mistri::Providers::Fake.new(turns: [
                                             { tool_calls: [{ name: "edit_file",
                                                              arguments:
                                                                headline_edit("Agent") }] },
                                             { text: "done" }
                                           ])
    events = []
    agent = Mistri::Agent.new(provider:, tools: [tool(workspace)])

    agent.run("edit") { |event| events << event }
    starts = events.count { |event| event.type == :tool_started }

    assert_equal 1, starts
    results = events.select { |event| event.type == :tool_result }

    assert_equal 1, results.length
    refute results.first.tool_error
    assert_equal 1, agent.session.messages.count(&:tool?)
  end

  def test_legacy_workspaces_keep_the_original_route
    workspace = LegacyWorkspace.new(page)

    result = tool(workspace).call(headline_edit("Agent"))

    assert_equal "Replaced 1 occurrence(s) in page.html", result
    assert_equal 1, workspace.reads
    assert_equal 1, workspace.writes
  end

  def test_incomplete_atomic_claims_fail_at_tool_construction
    atomic_methods = %i[snapshot compare_and_write]
    atomic_methods.each do |present|
      workspace = Object.new
      workspace.define_singleton_method(:atomic_writes?) { true }
      workspace.define_singleton_method(present) { |*| nil }

      error = assert_raises(Mistri::ConfigurationError) { tool(workspace) }
      missing = (atomic_methods - [present]).first

      assert_includes error.message, missing.to_s
    end
  end

  def test_atomic_claim_must_be_boolean
    workspace = Object.new
    workspace.define_singleton_method(:atomic_writes?) { :sometimes }

    error = assert_raises(Mistri::ConfigurationError) { tool(workspace) }

    assert_match(/must return true or false/, error.message)
  end

  private

  def tool(workspace) = Mistri::Tools.edit_file(workspace)

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
