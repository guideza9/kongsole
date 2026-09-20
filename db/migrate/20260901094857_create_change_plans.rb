class CreateChangePlans < ActiveRecord::Migration[8.1]
  def change
    create_table :change_plans do |t|
      t.references :kong_connection, null: false, foreign_key: true
      t.string :actor_username, null: false
      t.string :actor_operator
      t.string :actor_kind, null: false, default: "human"
      t.string :operation, null: false
      t.string :entity_type, null: false
      t.uuid :target_kong_id
      t.jsonb :before, null: false, default: {}
      t.jsonb :after, default: {}
      t.jsonb :diff, null: false, default: {}
      t.string :apply_mode, null: false
      t.datetime :base_updated_at
      t.string :status, null: false, default: "pending"
      t.datetime :expires_at, null: false
      t.string :pr_url
      t.integer :pr_number
      t.string :pr_state
      t.string :commit_sha
      t.jsonb :deck_diff

      t.timestamps
    end

    add_index :change_plans, [ :kong_connection_id, :status ]
  end
end
