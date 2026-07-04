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

  def test_the_directory_backend_refuses_path_escapes
    Dir.mktmpdir do |dir|
      workspace = Mistri::Workspace::Directory.new(dir)

      assert_raises(Mistri::SchemaError) { workspace.read("../../etc/passwd") }
      assert_raises(Mistri::SchemaError) { workspace.write("/etc/hostile", "x") }
    end
  end

  private

  def each_workspace
    yield Mistri::Workspace::Memory.new
    Dir.mktmpdir { |dir| yield Mistri::Workspace::Directory.new(dir) }
  end
end
