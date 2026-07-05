class CreateAgentEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_entries do |t|
      t.string :session_id, null: false, index: true
      t.integer :position, null: false
      t.text :payload, null: false
      t.timestamps
    end

    # One session has one writer; a colliding append must raise, never
    # silently reorder entries.
    add_index :agent_entries, [:session_id, :position], unique: true
  end
end
