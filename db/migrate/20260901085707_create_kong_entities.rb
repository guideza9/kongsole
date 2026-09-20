class CreateKongEntities < ActiveRecord::Migration[8.1]
  def change
    create_table :kong_entities do |t|
      t.references :kong_connection, null: false, foreign_key: true
      t.string :entity_type, null: false
      t.uuid :kong_id, null: false
      t.citext :name
      t.citext :logical_key
      t.text :tags, array: true, default: [], null: false
      t.datetime :kong_created_at
      t.datetime :kong_updated_at
      t.string :parent_type
      t.uuid :parent_kong_id
      t.boolean :enabled
      t.boolean :is_admin_path, null: false, default: false
      t.jsonb :data, null: false, default: {}
      t.string :digest
      t.datetime :not_after
      t.datetime :first_seen_at, null: false
      t.datetime :synced_at, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :kong_entities, [ :kong_connection_id, :entity_type, :kong_id ], unique: true, name: "index_kong_entities_on_connection_type_kong_id"
    add_index :kong_entities, [ :kong_connection_id, :entity_type, :name, :id ], name: "index_kong_entities_on_connection_type_name"
    add_index :kong_entities, [ :kong_connection_id, :entity_type, :kong_created_at, :id ], order: { kong_created_at: :desc, id: :desc }, name: "index_kong_entities_on_connection_type_created"
    add_index :kong_entities, [ :kong_connection_id, :entity_type, :kong_updated_at, :id ], order: { kong_updated_at: :desc, id: :desc }, name: "index_kong_entities_on_connection_type_updated"
    add_index :kong_entities, [ :kong_connection_id, :entity_type, :not_after ], where: "not_after IS NOT NULL", name: "index_kong_entities_on_connection_type_not_after"
    add_index :kong_entities, :tags, using: :gin
    add_index :kong_entities, :data, using: :gin, opclass: :jsonb_path_ops, name: "index_kong_entities_on_data_jsonb_path_ops"
    add_index :kong_entities, :name, using: :gin, opclass: :gin_trgm_ops, name: "index_kong_entities_on_name_trgm"
  end
end
