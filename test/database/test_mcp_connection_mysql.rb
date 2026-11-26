# frozen_string_literal: true

require_relative "../test_helper"

url = ENV.fetch("MISTRI_MYSQL_URL", nil)
abort "MISTRI_MYSQL_URL is required for the MySQL MCP connection suite" if url.to_s.empty?

require "active_record"
require "active_support/all"
require "erb"
require "mysql2"
require_relative "../support/stub_server"

ActiveRecord::Base.establish_connection(url)
ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32,
                                   key_derivation_salt: "s" * 32)
ActiveRecord::Base.connection.create_table(:mcp_connections, force: true,
                                                             options: "ENGINE=InnoDB") do |t|
  t.string :name, null: false
  t.string :url, null: false
  t.string :status, null: false, default: "pending"
  t.string :state
  t.string :code_verifier
  t.string :redirect_uri
  t.string :client_id
  t.string :client_secret
  t.string :issuer
  t.string :token_auth_method
  t.text :access_token
  t.text :refresh_token
  t.datetime :expires_at
  t.string :scope
  t.timestamps
end

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

template = File.expand_path("../../lib/generators/mistri/mcp/templates/model.rb.tt", __dir__)
model = ERB.new(File.read(template)).result_with_hash(class_name: "McpConnection")
eval(model, TOPLEVEL_BINDING, template) # rubocop:disable Security/Eval -- the gem's own template

# The generated connection model on a real row lock, against a token endpoint
# that retires a refresh token when it is used.
class TestMcpConnectionMysql < Minitest::Test
  def setup
    @spent = []
    @server = Mistri::Test::StubServer.new { |socket, request| route(socket, request) }
    McpConnection.define_singleton_method(:mcp_allow_non_public) { Mistri::Test::ALLOW_LOOPBACK }
    @row = McpConnection.create!(
      name: "notes", url: "#{@server.origin}/mcp", status: "connected", client_id: "app",
      issuer: @server.origin, token_auth_method: "none", access_token: "at-0",
      refresh_token: "rt-0", expires_at: 10.seconds.ago
    )
  end

  def teardown
    McpConnection.delete_all
    @server.stop
  end

  def test_two_refreshes_at_the_same_moment_spend_one_refresh_token
    gate = Queue.new
    readers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          stale = McpConnection.find(@row.id)
          gate.pop
          stale.bearer_token
        end
      end
    end
    sleep 0.01 until gate.num_waiting == 2
    2.times { gate << :go }

    assert_equal %w[at-1 at-1], readers.map(&:value)
    assert_equal ["rt-0"], @spent
    assert_equal "rt-1", McpConnection.find(@row.id).refresh_token
  end

  def test_a_refused_token_is_replaced_only_while_it_is_the_stored_one
    @row.update!(expires_at: 1.hour.from_now)

    assert_equal "at-0", @row.bearer_token(refused: "an-older-token")
    assert_empty @spent
    assert_equal "at-1", @row.bearer_token(refused: "at-0")
    assert_equal ["rt-0"], @spent
  end

  def test_a_good_token_and_one_with_no_refresh_token_are_returned_as_they_are
    @row.update!(expires_at: 1.hour.from_now)

    assert_equal "at-0", @row.bearer_token

    @row.update!(expires_at: 10.seconds.ago, refresh_token: nil)

    assert_equal "at-0", @row.bearer_token
    assert_equal "at-0", @row.bearer_token(refused: "at-0")
    assert_empty @spent
  end

  private

  def route(socket, request)
    path = request[:line].split[1]
    if path == "/.well-known/oauth-authorization-server"
      @server.respond_json(socket, { "issuer" => @server.origin,
                                     "token_endpoint" => "#{@server.origin}/token" })
    elsif path == "/token"
      refresh(socket, URI.decode_www_form(request[:body]).to_h["refresh_token"])
    else
      @server.respond_json(socket, { "error" => "not found" }, status: 404)
    end
  end

  # Slow enough that two refreshes started together overlap.
  def refresh(socket, sent)
    sleep 0.3
    current = "rt-#{@spent.length}"
    @spent << sent
    unless sent == current
      return @server.respond_json(socket, { "error" => "invalid_grant" },
                                  status: 400)
    end

    @server.respond_json(socket, { "access_token" => "at-#{@spent.length}",
                                   "refresh_token" => "rt-#{@spent.length}",
                                   "token_type" => "Bearer", "expires_in" => 3600 })
  end
end
