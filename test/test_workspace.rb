# frozen_string_literal: true

require "tmpdir"
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
    assert_raises(Mistri::SchemaError) { workspace.delete("page.html") }
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
