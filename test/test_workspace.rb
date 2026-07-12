# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rbconfig"
require_relative "test_helper"

class TestWorkspace < Minitest::Test
  def test_documents_round_trip_through_each_backend
    each_workspace do |workspace|
      assert_nil workspace.read("page.html")
      workspace.write("page.html", "<h1>Hi</h1>")

      assert_equal "<h1>Hi</h1>", workspace.read("page.html")
      workspace.write("assets/style.css", "body {}")

      assert_equal ["assets/style.css", "page.html"], workspace.list
      assert_equal ["assets/style.css"], workspace.list("assets/")
      workspace.delete("page.html")

      assert_nil workspace.read("page.html")
    end
  end

  def test_public_workspace_files_load_directly_with_their_atomic_contract
    script = <<~RUBY
      require "mistri/workspace/memory"
      require "mistri/workspace/single"
      require "mistri/workspace/directory"
      require "mistri/workspace/active_record"

      workspace = Mistri::Workspace::Memory.new
      created = workspace.compare_and_write("x", "one", expected_revision: nil)
      begin
        workspace.compare_and_write("x", "two", expected_revision: nil)
      rescue Mistri::WorkspaceConflictError
        puts created.content
      end
    RUBY
    lib = File.expand_path("../lib", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{lib}", "-e", script)

    assert_predicate status, :success?, stderr
    assert_equal "one\n", stdout
  end

  def test_memory_snapshots_bind_conditional_writes_to_exact_content
    workspace = Mistri::Workspace::Memory.new

    assert_nil workspace.snapshot("page.html")
    created = workspace.compare_and_write("page.html", "one", expected_revision: nil)
    unchanged = workspace.snapshot("page.html")

    assert_equal "one", created.content
    assert_equal created, unchanged
    assert_predicate created.content, :frozen?
    assert_predicate created.revision, :frozen?

    replaced = workspace.compare_and_write(
      "page.html", "two", expected_revision: created.revision
    )

    assert_equal "two", replaced.content
    refute_equal created.revision, replaced.revision

    error = assert_raises(Mistri::WorkspaceConflictError) do
      workspace.compare_and_write("page.html", "stale", expected_revision: created.revision)
    end

    assert_equal "page.html", error.path
    assert_equal created.revision, error.expected_revision
    assert_equal replaced.revision, error.actual_revision
    assert_equal "two", workspace.read("page.html")
  end

  def test_memory_nil_revision_is_create_only
    workspace = Mistri::Workspace::Memory.new
    workspace.compare_and_write("page.html", "winner", expected_revision: nil)

    assert_raises(Mistri::WorkspaceConflictError) do
      workspace.compare_and_write("page.html", "loser", expected_revision: nil)
    end

    assert_equal "winner", workspace.read("page.html")
  end

  def test_memory_reads_cannot_mutate_the_committed_document
    workspace = Mistri::Workspace::Memory.new
    workspace.write("page.html", +"committed")

    workspace.read("page.html").replace("outside write")

    assert_equal "committed", workspace.read("page.html")
  end

  def test_snapshot_owns_content_and_revision
    content = +"mutable"
    revision = +"revision-1"
    snapshot = Mistri::Workspace::Snapshot.new(content:, revision:)

    content.replace("changed")
    revision.replace("changed")

    assert_equal "mutable", snapshot.content
    assert_equal "revision-1", snapshot.revision
    assert_raises(FrozenError) { snapshot.content << "!" }
    assert_raises(FrozenError) { snapshot.revision << "!" }
  end

  def test_snapshot_factory_hashes_the_bytes_it_owns
    source = +"mutable"
    snapshot = Mistri::Workspace::Snapshot.for(source)
    source.replace("changed")

    assert_equal "mutable", snapshot.content
    assert_equal Digest::SHA256.hexdigest(snapshot.content.b), snapshot.revision
  end

  def test_snapshot_factory_does_not_dispatch_to_a_string_subclass
    hostile_string = Class.new(String) do
      def b
        copy = super
        replace("changed during hashing")
        copy
      end
    end

    snapshot = Mistri::Workspace::Snapshot.for(hostile_string.new("stable"))

    assert_equal "stable", snapshot.content
    assert_equal Digest::SHA256.hexdigest("stable"), snapshot.revision
    assert_instance_of String, snapshot.content
  end

  def test_snapshot_revisions_are_opaque_bounded_bytes
    revision = "\x00raw\nrevision".b
    snapshot = Mistri::Workspace::Snapshot.new(content: "text", revision:)

    assert_equal revision, snapshot.revision
    assert_instance_of String, snapshot.revision
  end

  def test_snapshot_rejects_unusable_revisions
    invalid = ["", "x" * 257, 1]

    invalid.each do |revision|
      assert_raises(ArgumentError) do
        Mistri::Workspace::Snapshot.new(content: "text", revision:)
      end
    end
  end

  def test_a_single_document_workspace_wraps_any_column
    record = { html: "<h1>Old</h1>" }
    workspace = Mistri::Workspace::Single.new(
      path: "page.html",
      read: -> { record[:html] },
      write: ->(content) { record[:html] = content }
    )
    edit = Mistri::Tools.files(workspace).find { |tool| tool.name == "edit_file" }

    reply = edit.call({ "path" => "page.html", "old_string" => "Old", "new_string" => "New" })

    assert_equal "Replaced 1 occurrence(s) in page.html", reply
    assert_equal "<h1>New</h1>", record[:html]
    assert_equal ["page.html"], workspace.list
    assert_nil workspace.read("other.html")
    refute_predicate workspace, :atomic_writes?
    assert_raises(Mistri::SchemaError) { workspace.delete("page.html") }
  end

  def test_single_rejects_an_invalid_synchronizer
    error = assert_raises(ArgumentError) do
      Mistri::Workspace::Single.new(read: -> { "text" }, write: ->(_text) {},
                                    synchronize: :not_callable)
    end

    assert_match(/must be callable/, error.message)
  end

  def test_single_cannot_conditionally_write_without_a_synchronizer
    workspace = Mistri::Workspace::Single.new(read: -> { "text" }, write: ->(_text) {})

    error = assert_raises(Mistri::ConfigurationError) do
      workspace.compare_and_write("document", "new", expected_revision: "revision")
    end

    assert_match(/needs synchronize/, error.message)
  end

  def test_single_rejects_a_write_to_another_path
    wrote = false
    workspace = Mistri::Workspace::Single.new(
      path: "page.html", read: -> { "text" }, write: ->(_text) { wrote = true }
    )

    error = assert_raises(Mistri::SchemaError) { workspace.write("other.html", "new") }

    assert_match(/only "page.html"/, error.message)
    refute wrote
  end

  def test_a_synchronized_single_document_supports_atomic_writes
    record = { html: "<h1>Old</h1>" }
    mutex = Mutex.new
    synchronizations = 0
    workspace = Mistri::Workspace::Single.new(
      path: "page.html",
      read: -> { record[:html] },
      write: ->(content) { record[:html] = content },
      synchronize: lambda { |&operation|
        synchronizations += 1
        mutex.synchronize(&operation)
      }
    )
    before = workspace.snapshot("page.html")

    after = workspace.compare_and_write(
      "page.html", "<h1>New</h1>", expected_revision: before.revision
    )

    assert_predicate workspace, :atomic_writes?
    assert_equal "<h1>New</h1>", after.content
    assert_equal "<h1>New</h1>", record[:html]
    assert_nil workspace.snapshot("other.html")
    assert_equal 1, synchronizations

    assert_raises(Mistri::WorkspaceConflictError) do
      workspace.compare_and_write(
        "page.html", "<h1>Stale</h1>", expected_revision: before.revision
      )
    end
    assert_equal "<h1>New</h1>", record[:html]
  end

  def test_a_single_document_workspace_owns_its_path
    path = +"page.html"
    record = { html: "content" }
    workspace = Mistri::Workspace::Single.new(
      path:,
      read: -> { record[:html] },
      write: ->(content) { record[:html] = content },
      synchronize: ->(&operation) { operation.call }
    )
    path.replace("other.html")

    assert_equal "content", workspace.read("page.html")
    assert_nil workspace.read("other.html")
  end

  def test_the_directory_backend_refuses_path_escapes
    Dir.mktmpdir do |dir|
      workspace = Mistri::Workspace::Directory.new(dir)

      assert_raises(Mistri::SchemaError) { workspace.read("../../etc/passwd") }
      assert_raises(Mistri::SchemaError) { workspace.write("/etc/hostile", "x") }
    end
  end

  def test_the_directory_backend_refuses_symlinks_to_outside_directories
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        secret = File.join(outside, "secret.txt")
        File.write(secret, "private")
        File.symlink(outside, File.join(root, "linked"))
        workspace = Mistri::Workspace::Directory.new(root)

        assert_raises(Mistri::SchemaError) { workspace.read("linked/secret.txt") }
        assert_raises(Mistri::SchemaError) { workspace.write("linked/new.txt", "hostile") }
        assert_raises(Mistri::SchemaError) { workspace.delete("linked/secret.txt") }
        assert_empty workspace.list
        assert_equal "private", File.read(secret)
        refute_path_exists File.join(outside, "new.txt")
      end
    end
  end

  def test_the_directory_backend_refuses_file_and_broken_symlinks
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        secret = File.join(outside, "secret.txt")
        missing = File.join(outside, "missing.txt")
        File.write(secret, "private")
        File.symlink(secret, File.join(root, "secret.txt"))
        File.symlink(missing, File.join(root, "missing.txt"))
        workspace = Mistri::Workspace::Directory.new(root)

        assert_empty workspace.list
        assert_raises(Mistri::SchemaError) { workspace.read("secret.txt") }
        assert_raises(Mistri::SchemaError) { workspace.write("secret.txt", "hostile") }
        assert_raises(Mistri::SchemaError) { workspace.write("missing.txt", "hostile") }
        assert_raises(Mistri::SchemaError) { workspace.delete("secret.txt") }
        assert_equal "private", File.read(secret)
        refute_path_exists missing
      end
    end
  end

  def test_the_directory_backend_omits_safe_directory_symlinks
    Dir.mktmpdir do |root|
      workspace = Mistri::Workspace::Directory.new(root)
      workspace.write("real/inside.txt", "inside")
      File.symlink(File.join(root, "real"), File.join(root, "linked"))

      assert_raises(Mistri::SchemaError) { workspace.read("linked/inside.txt") }
      assert_equal ["real/inside.txt"], workspace.list
    end
  end

  def test_the_directory_backend_accepts_children_of_the_filesystem_root
    workspace = Mistri::Workspace::Directory.new(File::SEPARATOR)
    missing = "mistri-workspace-missing-#{Process.pid}-#{object_id}"

    assert_nil workspace.read(missing)
  end

  def test_the_directory_backend_treats_a_canonical_root_as_a_literal_path
    Dir.mktmpdir do |parent|
      root = File.join(parent, "workspace[1]")
      FileUtils.mkdir_p(root)
      link = File.join(parent, "workspace")
      File.symlink(root, link)
      workspace = Mistri::Workspace::Directory.new(link)

      workspace.write("notes/one.txt", "one")

      assert_equal ["notes/one.txt"], workspace.list
    end
  end

  private

  def each_workspace
    yield Mistri::Workspace::Memory.new
    Dir.mktmpdir { |dir| yield Mistri::Workspace::Directory.new(dir) }
  end
end
