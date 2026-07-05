class CreateMcpConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_connections do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.string :status, null: false, default: "pending"

      # OAuth flow state; cleared once connected.
      t.string :state
      t.string :code_verifier
      t.string :redirect_uri

      t.string :client_id
      t.string :client_secret
      t.string :token_endpoint
      t.text :access_token
      t.text :refresh_token
      t.datetime :expires_at
      t.string :scope
      t.timestamps
    end

    # The callback finds its pending row by state.
    add_index :mcp_connections, :state, unique: true
  end
end
