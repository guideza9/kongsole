class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_events do |t|
      t.references :kong_connection, null: false, foreign_key: true
      t.references :change_plan, foreign_key: true
      t.string :actor_username, null: false
      t.string :actor_operator
      t.string :actor_kind, null: false, default: "human"
      t.string :operation, null: false
      t.string :entity_type, null: false
      t.uuid :target_kong_id
      t.string :entity_name
      t.jsonb :diff, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :audit_events, [ :kong_connection_id, :created_at ]
  end
end
